$plannerDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $plannerDir 'ZabbixHostImportCommon.ps1')

function Select-ZabbixMigrationRows {
    param([object[]]$Rows, [string]$Label)
    if ($Rows.Count -eq 0) { Write-Warning 'No entries are available to select.'; return 'B' }
    while ($true) {
        $display = @(for ($i = 0; $i -lt $Rows.Count; $i++) {
            [PSCustomObject]@{ Number = $i + 1; Name = $Rows[$i].name; Id = $Rows[$i].id }
        })
        $display | Format-Table -AutoSize | Out-Host
        $answer = (Read-Host "${Label}: numbers separated by commas, [A] All, [B] Back, [Q] Cancel").Trim()
        if ($answer -ieq 'B' -or $answer -ieq 'Q') { return $answer.ToUpperInvariant() }
        if ($answer -ieq 'A') { return ,$Rows }
        $indices = @($answer.Split(',') | ForEach-Object { $_.Trim() } | Select-Object -Unique)
        $valid = $indices.Count -gt 0
        $selected = @()
        foreach ($index in $indices) {
            $number = 0
            if (-not [int]::TryParse($index, [ref]$number) -or $number -lt 1 -or $number -gt $Rows.Count) {
                $valid = $false; break
            }
            $selected += $Rows[$number - 1]
        }
        if ($valid) { return ,$selected }
        Write-Warning 'Select valid listed numbers or A, B, Q.'
    }
}

function Select-ZabbixMigrationHosts {
    param([string[]]$ResumeHostIds)
    if ($ResumeHostIds) {
        return @(Invoke-ZabbixExampleRequest -Method 'host.get' -Parameters @{
            hostids = $ResumeHostIds; output = @('hostid', 'host', 'name', 'status')
            selectInterfaces = 'extend'; selectParentTemplates = @('templateid', 'host')
            selectMacros = @('macro', 'value', 'type')
        })
    }
    while ($true) {
        $groups = @(Invoke-ZabbixExampleRequest -Method 'hostgroup.get' -Parameters @{ output = @('groupid', 'name') } |
            Sort-Object name | ForEach-Object { [PSCustomObject]@{ id = $_.groupid; name = $_.name } })
        if ($groups.Count -eq 0) { throw 'No accessible Zabbix host groups.' }
        $selection = Select-ZabbixMigrationRows -Rows $groups -Label 'Choose Zabbix groups'
        if ($selection -is [string]) {
            if ($selection -eq 'Q') { return }
            continue
        }
        $hosts = @(Invoke-ZabbixExampleRequest -Method 'host.get' -Parameters @{
            groupids = @($selection.id); output = @('hostid', 'host', 'name', 'status')
            filter = @{ status = '0' }; selectInterfaces = 'extend'
            selectParentTemplates = @('templateid', 'host'); selectMacros = @('macro', 'value', 'type')
        } | Sort-Object host)
        if ($hosts.Count -eq 0) { Write-Warning 'No enabled accessible hosts in those groups.'; continue }
        $rows = @($hosts | ForEach-Object { [PSCustomObject]@{ id = $_.hostid; name = "$($_.name) [$($_.host)]"; Host = $_ } })
        $selection = Select-ZabbixMigrationRows -Rows $rows -Label 'Choose Zabbix hosts'
        if ($selection -is [string]) {
            if ($selection -eq 'Q') { return }
            continue
        }
        return @($selection.Host)
    }
}

function Get-ZabbixMigrationTemplates {
    param([object[]]$Roots)
    $templates = @{}
    $pending = @($Roots | ForEach-Object { $_.templateid } | Where-Object { $_ } | Select-Object -Unique)
    for ($depth = 0; $pending.Count -gt 0; $depth++) {
        if ($depth -ge 32) { throw 'Template ancestry exceeds 32 levels.' }
        $batch = @(Invoke-ZabbixExampleRequest -Method 'template.get' -Parameters @{
            templateids = $pending; output = @('templateid', 'host')
            selectParentTemplates = @('templateid', 'host'); selectMacros = @('macro', 'value', 'type')
        })
        foreach ($id in $pending) {
            if (@($batch | Where-Object { $_.templateid -eq $id }).Count -ne 1) { throw "Inaccessible ancestor template '$id'." }
        }
        foreach ($template in $batch) { $templates[[string]$template.templateid] = $template }
        $pending = @($batch | ForEach-Object { $_.parentTemplates } |
            Where-Object { -not $templates.ContainsKey([string]$_.templateid) } |
            Select-Object -ExpandProperty templateid -Unique)
    }
    return @($templates.Values)
}

function Get-ZabbixMigrationInterval {
    param([string]$Delay)
    if (-not $Delay) { $Delay = '1m' }
    if ($Delay -notmatch '^([1-9][0-9]{0,5})([smhd]?)$') { return 0 }
    $factor = switch ($Matches[2]) { 'm' { 60 } 'h' { 3600 } 'd' { 86400 } default { 1 } }
    $seconds = [long]$Matches[1] * $factor
    if ($seconds -lt 10 -or $seconds -gt 86400) { return 0 }
    return [int]$seconds
}

function New-ZabbixMigrationDefinition {
    param([string]$HostName, $Item, [string]$Status = 'Deferred', [string]$Reason)
    [PSCustomObject]@{
        Id = Get-ZabbixDefinitionId "$HostName|$($Item.itemid)"
        Kind = 'Item'; Name = "Item $($Item.itemid)"; Location = "item.get/$($Item.itemid)"
        Status = $Status; Reasons = @($Reason); Candidate = $null
    }
}

function ConvertTo-ZabbixMigrationProfile {
    param($HostInfo, [object[]]$Items, [object[]]$Triggers, [object[]]$Rules, [object[]]$WebScenarios,
        [string]$SnmpInterfaceId)
    $definitions = [System.Collections.Generic.List[object]]::new()
    $normalized = @()
    foreach ($item in $Items) {
        if (-not $item.itemid) { throw 'Zabbix returned an item without an ID.' }
        $data = ConvertTo-ZabbixData $item
        $data['key'] = [string]$item.key_
        $data['name'] = "Item $($item.itemid)"
        if ([string]$item.type -eq '20') { $data['type'] = 'SNMP_AGENT' }
        if ($SnmpInterfaceId -and $item.type -in @('1', '4', '6', '20') -and $item.interfaceid -ne $SnmpInterfaceId) {
            $data['status'] = '1'
        }
        $normalized += $data
    }
    foreach ($item in $Items) {
        $data = @($normalized | Where-Object { $_.itemid -eq $item.itemid })[0]
        $definition = New-ZabbixMigrationDefinition -HostName $HostInfo.host -Item $item -Reason 'No verified translation for this effective host item.'
        $interval = Get-ZabbixMigrationInterval $item.delay
        if ([string]$item.status -ne '0') {
            $definition.Status = 'Disabled'; $definition.Reasons = @('Disabled in effective host configuration.')
        }
        elseif ($item.preprocessing -or [string]$item.type -eq '18') {
            $definition.Reasons = @('Preprocessing/dependent items need verified transforms; no raw substitute.')
        }
        elseif ([string]$item.type -eq '17') {
            ConvertTo-ZabbixTrapCandidate -Definition $definition -Item $data -TemplateName $HostInfo.host -Prototype:$false
        }
        elseif ($interval -eq 0) {
            $definition.Reasons = @('Resolve fixed polling schedule/macros; no rounding or scheduling guess.')
        }
        elseif ([string]$item.type -eq '20' -or [string]$item.type -in @('1', '4', '6')) {
            ConvertTo-ZabbixSnmpCandidate -Definition $definition -Item $data -TemplateName $HostInfo.host -Prototype:$false
            if ($definition.Candidate) {
                $definition.Candidate | Add-Member -NotePropertyName Semantics -NotePropertyValue 'EffectiveHostSnapshot' -Force
            }
        }
        elseif ([string]$item.type -eq '3' -and [string]$item.key_ -match '^icmpping(?:\[\])?$') {
            New-ZabbixMonitorCandidate $definition "$($HostInfo.host) - Ping item $($item.itemid)" 'active' 'Ping' `
                '2655476e-36b0-455f-9cce-940b6f8e07bf' @{ Timeout = '5'; Retries = '1'; PayloadSize = '32' } 'WUGNativeAlternative'
            $definition.Status = 'Review'
            $definition.Reasons = @('WUG-native reachability alternative; packet timing/count and Zabbix trigger history are not reproduced.')
        }
        elseif ([string]$item.type -eq '3' -and [string]$item.key_ -match '^net\.tcp\.service\[tcp,,([0-9]+)\]$') {
            $port = [int]$Matches[1]
            if ($port -ge 1 -and $port -le 65535) {
                New-ZabbixMonitorCandidate $definition "$($HostInfo.host) - TCP item $($item.itemid)" 'active' 'TcpIp' `
                    '1ee6ecd4-4c17-4ccc-8ff8-3147f445943f' @{ Timeout = '5'; Protocol = 'TCP'; Port = [string]$port; Script = '' } 'WUGNativeAlternative'
                $definition.Status = 'Review'
                $definition.Reasons = @('WUG-native TCP connection alternative; source trigger semantics require separate review.')
            }
        }
        elseif ([string]$item.type -eq '19') {
            $uri = $null
            $safeUrl = [string]$item.url -notmatch '\{\$|\{#|\{HOST\.' -and
                [uri]::TryCreate([string]$item.url, [UriKind]::Absolute, [ref]$uri) -and
                $uri.Scheme -in @('http', 'https') -and -not $uri.UserInfo -and -not $uri.Query -and -not $uri.Fragment
            if ($safeUrl -and [string]$item.request_method -eq '0' -and [string]$item.authtype -eq '0' -and
                -not $item.headers -and -not $item.posts -and -not $item.query_fields -and
                -not $item.http_proxy -and [string]$item.follow_redirects -eq '0' -and
                [string]$item.verify_peer -eq '1' -and [string]$item.verify_host -eq '1') {
                New-ZabbixMonitorCandidate $definition "$($HostInfo.host) - HTTP item $($item.itemid)" 'active' 'RestApi' `
                    'f0610672-d515-4268-bd21-ac5ebb1476ff' @{
                        'MonRestApi:RestUrl' = $uri.AbsoluteUri; 'MonRestApi:HttpMethod' = 'GET'
                        'MonRestApi:HttpTimeoutMs' = '10000'; 'MonRestApi:IgnoreCertErrors' = 'False'
                        'MonRestApi:UseAnonymousAccess' = 'True'; 'MonRestApi:CustomHeader' = ''
                        'MonRestApi:DownIfResponseCodeIsIn' = ''; 'MonRestApi:ComparisonList' = ''; 'Cred:Type' = '8192'
                    } 'WUGNativeAlternative'
                $definition.Status = 'Review'
                $definition.Reasons = @('GET connectivity alternative only. Confirm expected status/content/timeout in WUG; raw item values and Zabbix alert logic are not reproduced.')
            }
            else { $definition.Reasons = @('HTTP method/auth/headers/body/redirect/TLS/query semantics need deliberate WUG configuration; select a reviewed existing monitor.') }
        }
        elseif ([string]$item.type -eq '13') {
            $definition.Reasons = @('SSH command/output semantics require a reviewed WUG SSH monitor. Imported commands are never executed during discovery.')
        }
        elseif ([string]$item.type -eq '11') {
            $definition.Reasons = @('ODBC DSN/query/row semantics are not equivalent to a WUG SQL connection; select a reviewed existing SQL monitor.')
        }
        elseif ([string]$item.key_ -match '^(system\.cpu|vm\.memory|vfs\.fs|service\.)') {
            $definition.Reasons = @('Select a WUG-native CPU/memory/disk/service alternative after reviewing units, credentials and thresholds; no Zabbix agent equivalence is assumed.')
        }
        if ($definition.Candidate -and $definition.Candidate.Template.monitorTypeInfo.baseType -eq 'active') {
            $definition.Candidate | Add-Member -NotePropertyName PollingIntervalSeconds -NotePropertyValue $interval -Force
        }
        $definitions.Add($definition)
    }
    $context = [PSCustomObject]@{ Lineage = @($HostInfo.host); Items = $normalized; TableDiscovery = @{} }
    foreach ($trigger in $Triggers) {
        $definition = New-ZabbixMigrationDefinition -HostName $HostInfo.host `
            -Item ([PSCustomObject]@{ itemid = "trigger-$($trigger.triggerid)" }) -Reason 'Trigger needs review.'
        $definition.Kind = 'Trigger'
        $data = ConvertTo-ZabbixData $trigger
        $data['name'] = "Trigger $($trigger.triggerid)"
        # API expression expansion is requested explicitly; unknown syntax is deferred by the converter.
        ConvertTo-ZabbixActiveCandidate -Definition $definition -Trigger $data -TemplateName $HostInfo.host -Context $context
        if ([string]$trigger.status -ne '0') { $definition.Status = 'Disabled'; $definition.Candidate = $null }
        elseif ($definition.Candidate) {
            $definition.Candidate | Add-Member -NotePropertyName PollingIntervalSeconds -NotePropertyValue 60 -Force
            $definition.Status = 'Review'
            $definition.Reasons = @('Current-value comparison only; approve the WUG 60-second polling cadence independently of Zabbix alert scheduling.')
        }
        $definitions.Add($definition)
    }
    foreach ($rule in $Rules) {
        $definitions.Add((New-ZabbixMigrationDefinition -HostName $HostInfo.host `
            -Item ([PSCustomObject]@{ itemid = "lld-$($rule.itemid)" }) `
            -Reason 'Live discovery rule preserved as a requirement: importing resolved instances does not reproduce rescan or lost-resource lifecycle.'))
    }
    foreach ($scenario in $WebScenarios) {
        $definitions.Add((New-ZabbixMigrationDefinition -HostName $HostInfo.host `
            -Item ([PSCustomObject]@{ itemid = "web-$($scenario.httptestid)" }) `
            -Reason 'Multi-step web scenario cookies/auth/status/content/timing require a reviewed existing WUG monitor; no flattening into one GET.'))
    }
    [PSCustomObject]@{ Template = $HostInfo.host; Definitions = $definitions.ToArray(); Validation = 'OfflineOnly' }
}

function Get-ZabbixMigrationCredentials {
    param($Plan, [object[]]$Items, [object[]]$HostMacros, [object[]]$Templates, [object[]]$WebScenarios)
    Get-ZabbixExampleAdditionalCredentials -Plan $Plan -Items @($Items | Where-Object { $_.type -eq '13' -and $_.status -eq '0' }) `
        -HostMacros $HostMacros -Templates $Templates
    foreach ($item in @($Items | Where-Object { $_.type -eq '13' -and $_.status -eq '0' -and $_.authtype -eq '1' })) {
        $sourceKey = "$($Plan.Host)|ssh-key-$($item.itemid)"
        $credentialSources[$sourceKey] = @{}
        [PSCustomObject]@{
            Host = $Plan.Host; CredentialType = 'ssh'; SourceKey = $sourceKey; AuthMode = 'ExistingOnly'
            Label = "SSH key authentication item $($item.itemid) (no password downgrade)"
            SourceNames = @("item.get/$($item.itemid)"); Prefix = "$($Plan.Prefix)SSH key $($item.itemid) - "
        }
    }
    foreach ($item in @($Items | Where-Object { $_.type -in @('19', '11') -and $_.status -eq '0' })) {
        $type = if ($item.type -eq '11') { 'ado' } else { 'restapi' }
        if ($type -eq 'restapi' -and [string]$item.authtype -eq '0' -and -not $item.headers) { continue }
        $sourceKey = "$($Plan.Host)|$type-item-$($item.itemid)"
        $credentialSources[$sourceKey] = Get-ZabbixExampleCredentialSource -Details $item -HostMacros $HostMacros `
            -Templates $Templates -FieldNames @('username', 'password')
        $mode = if ($type -eq 'restapi' -and [string]$item.authtype -ne '1') { 'ExistingOnly' } else { 'Basic' }
        [PSCustomObject]@{
            Host = $Plan.Host; CredentialType = $type; SourceKey = $sourceKey; AuthMode = $mode
            Label = "$type item $($item.itemid)"; SourceNames = @("item.get/$($item.itemid)")
            Prefix = "$($Plan.Prefix)$type item $($item.itemid) - "
        }
    }
    foreach ($scenario in $WebScenarios) {
        if ([string]$scenario.authentication -eq '0') { continue }
        $sourceKey = "$($Plan.Host)|web-$($scenario.httptestid)"
        $credentialSources[$sourceKey] = Get-ZabbixExampleCredentialSource -Details $scenario `
            -HostMacros $HostMacros -Templates $Templates -FieldNames @('username', 'password')
        [PSCustomObject]@{
            Host = $Plan.Host; CredentialType = 'restapi'; SourceKey = $sourceKey
            AuthMode = $(if ($scenario.authentication -eq '1') { 'Basic' } else { 'ExistingOnly' })
            Label = "web authentication $($scenario.httptestid)"; SourceNames = @("httptest.get/$($scenario.httptestid)")
            Prefix = "$($Plan.Prefix)web $($scenario.httptestid) - "
        }
    }
    $all = @($HostMacros) + @($Templates | ForEach-Object { $_.macros })
    $types = @{
        aws = @{ Pattern = '^\{\$AWS[_.]'; Fields = @{ accesskey = 'ACCESS_KEY_ID|ACCESSKEY|ACCESS_KEY'; secretkey = 'SECRET_ACCESS_KEY|SECRET_KEY|SECRETKEY' } }
        azure = @{ Pattern = '^\{\$AZURE[_.]'; Fields = @{ tenantid = 'TENANT_ID|TENANTID'; clientid = 'CLIENT_ID|CLIENTID'; clientsecret = 'CLIENT_SECRET|CLIENTSECRET' } }
        redfish = @{ Pattern = '^\{\$REDFISH[_.]'; Fields = @{ username = 'USERNAME|USER'; password = 'PASSWORD|PASS' } }
    }
    foreach ($type in @('aws', 'azure', 'redfish')) {
        $matching = @($all | Where-Object { $_.macro -match $types[$type].Pattern })
        if ($matching.Count -eq 0) { continue }
        $details = @{}
        foreach ($field in $types[$type].Fields.Keys) {
            $names = @($matching | Where-Object { $_.macro -match ("[_.](" + $types[$type].Fields[$field] + ")\}$") } |
                Select-Object -ExpandProperty macro -Unique)
            if ($names.Count -eq 1) { $details[$field] = $names[0] }
        }
        $sourceKey = "$($Plan.Host)|$type-macros"
        $credentialSources[$sourceKey] = Get-ZabbixExampleCredentialSource -Details ([PSCustomObject]$details) `
            -HostMacros $HostMacros -Templates $Templates -FieldNames @($types[$type].Fields.Keys)
        [PSCustomObject]@{
            Host = $Plan.Host; CredentialType = $type; SourceKey = $sourceKey; AuthMode = 'Basic'
            Label = "$type macro candidate (confirm identity and purpose)"
            SourceNames = @($matching | Select-Object -ExpandProperty macro -Unique); Prefix = "$($Plan.Prefix)$type - "
        }
    }
    foreach ($type in @('vmware', 'jmx')) {
        $matching = @($all | Where-Object { $_.macro -match ("^\{\$" + $type + "[_.]") })
        if ($matching.Count -eq 0) { continue }
        $sourceKey = "$($Plan.Host)|$type-macros"
        $credentialSources[$sourceKey] = @{}
        [PSCustomObject]@{
            Host = $Plan.Host; CredentialType = $type; SourceKey = $sourceKey; AuthMode = 'ExistingOnly'
            Label = "$type settings (existing WUG credential only; property mapping is not verified)"
            SourceNames = @($matching | Select-Object -ExpandProperty macro -Unique); Prefix = "$($Plan.Prefix)$type - "
        }
    }
}

function Save-ZabbixMigrationPlan {
    param([string]$Path, [object[]]$Plans, [string]$ApiUrl)
    $hosts = @($Plans | ForEach-Object {
        [ordered]@{
            HostId = $_.HostId; Fingerprint = $_.Fingerprint
            Selected = @($_.Profile.Definitions | Where-Object { $_.Status -eq 'Ready' } | ForEach-Object { $_.Id })
            Existing = @($_.ExistingMonitors | Select-Object Id, Type, Interval, DefinitionId, Fingerprint)
        }
    })
    $document = [ordered]@{ SchemaVersion = '1'; ApiUrl = $ApiUrl; WugUrl = $global:WhatsUpServerBaseURI; Hosts = $hosts }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $resolved) { throw 'Plan file already exists. Choose a new path; saved plans are not silently overwritten.' }
    $json = ConvertTo-Json -InputObject $document -Depth 20
    [System.IO.File]::WriteAllText($resolved, $json, [System.Text.UTF8Encoding]::new($true))
    Write-Verbose "Saved redacted plan to '$resolved'. Credentials and monitor payloads are deliberately excluded."
}

function Read-ZabbixMigrationPlan {
    param([string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 1048576) { throw 'Select a plan file no larger than 1 MiB.' }
    $plan = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop
    if ($plan.SchemaVersion -ne '1' -or @($plan.Hosts).Count -eq 0) { throw 'Invalid migration plan schema.' }
    if (@($plan.Hosts | Group-Object HostId | Where-Object { $_.Count -gt 1 }).Count -gt 0) { throw 'Duplicate host IDs in saved plan.' }
    foreach ($hostPlan in $plan.Hosts) {
        if ([string]$hostPlan.HostId -notmatch '^[0-9]+$' -or [string]$hostPlan.Fingerprint -notmatch '^[a-f0-9]{24}$') { throw 'Invalid plan host identity/fingerprint.' }
        foreach ($monitor in $hostPlan.Existing) {
            if (-not $monitor.Id -or $monitor.Type -notin @('active', 'performance', 'passive') -or
                [string]$monitor.Fingerprint -notmatch '^[a-f0-9]{24}$' -or
                ($monitor.Type -eq 'active' -and ($monitor.Interval -lt 10 -or $monitor.Interval -gt 86400)) -or
                ($monitor.Type -eq 'performance' -and ($monitor.Interval -lt 1 -or $monitor.Interval -gt 1440))) {
                throw 'Invalid existing monitor selection in saved plan.'
            }
        }
    }
    return $plan
}

function Review-ZabbixMigrationMonitors {
    param([object[]]$Plans)
    foreach ($plan in $Plans) {
        foreach ($definition in $plan.Profile.Definitions) {
            if ($definition.Status -in @('Disabled', 'Ready')) { continue }
            if (@($plan.ExistingMonitors | Where-Object { $_.DefinitionId -eq $definition.Id }).Count -gt 0) { continue }
            $definition | Select-Object Id, Name, Status, Reasons | Format-List | Out-Host
            if ($definition.Candidate) {
                if ((Read-Host "Use this explicitly labeled WUG-native alternative for $($plan.Host)? [Y/N]") -ieq 'Y') {
                    $definition.Status = 'Ready'; continue
                }
            }
            if ((Read-Host "Select a reviewed existing WUG monitor for this requirement? [Y/N]") -ine 'Y') { continue }
            $library = Get-WUGZabbixLibraryTemplates
            $rows = @($library.Values | Sort-Object name | ForEach-Object {
                [PSCustomObject]@{ id = $_.id; name = "$($_.name) [$($_.monitorTypeInfo.baseType)]"; Monitor = $_ }
            })
            $selected = Select-ZabbixMigrationRows -Rows $rows -Label 'Choose one existing monitor'
            if ($selected -is [string]) { continue }
            if (@($selected).Count -ne 1) { Write-Warning 'Choose one monitor per requirement.'; continue }
            $monitor = $selected[0].Monitor
            $type = $monitor.monitorTypeInfo.baseType
            $interval = 0
            if ($type -ne 'passive') {
                $unit = if ($type -eq 'active') { 'seconds (10-86400)' } else { 'minutes (1-1440)' }
                $inputValue = Read-Host "Reviewed assignment interval in $unit"
                if (-not [int]::TryParse($inputValue, [ref]$interval) -or
                    ($type -eq 'active' -and ($interval -lt 10 -or $interval -gt 86400)) -or
                    ($type -eq 'performance' -and ($interval -lt 1 -or $interval -gt 1440))) { throw 'Invalid assignment interval.' }
            }
            Write-Warning 'This is a user-selected WUG replacement, not a converted Zabbix check. Any SSH/SQL command in that monitor will run later on the WUG poller; review it before approving.'
            $plan.ExistingMonitors += [PSCustomObject]@{
                Id = [string]$monitor.id; Type = $type; Interval = $interval; DefinitionId = $definition.Id
                Fingerprint = Get-ZabbixMonitorFingerprint $monitor
            }
        }
    }
}

function Apply-ZabbixMigrationCredential {
    param($Credential)
    if ($Credential.id) { return $Credential }
    $existing = @(Get-WugExamplePages -Path 'credentials/-?view=basic&type=all&limit=250' |
        Where-Object { $_.name -eq $Credential.name })
    if ($existing.Count -gt 0) { throw "Credential '$($Credential.name)' now exists; reselect it before applying." }
    $arguments = @{ Name = $Credential.name; Type = $Credential.type; Description = 'Reviewed Zabbix migration credential; live validation required.' }
    try {
        Save-DiscoveryCredential -Name $Credential.VaultName -Fields $Credential.Fields -Description 'Reviewed Zabbix migration' `
            -Force -Confirm:$false -ErrorAction Stop | Out-Null
        foreach ($field in $Credential.Fields.Keys) {
            $arguments[$field] = [PSCredential]::new('value', $Credential.Fields[$field]).GetNetworkCredential().Password
        }
        if ($Credential.type -eq 'redfish') { $arguments['RedfishIgnoreCertErrors'] = 'False' }
        $created = Add-WUGCredential @arguments -Confirm:$false -ErrorAction Stop
        if (-not $created.id -or $created.type -ne $Credential.type -or $created.name -ne $Credential.name) { throw 'Credential creation was not confirmed. Vault data may remain.' }
        $confirmed = (Invoke-WugExampleRequest -Path ("credentials/" + [uri]::EscapeDataString([string]$created.id) + '?view=basic')).data
        if ($confirmed.id -ne $created.id -or $confirmed.type -ne $created.type) { throw 'Credential read-back failed.' }
        return $confirmed
    }
    finally { $arguments.Clear() }
}

function Invoke-ZabbixMigrationPlanner {
    <#
    .SYNOPSIS
        Guides effective-host Zabbix discovery, review, redacted plan saving and WUG application.
    .DESCRIPTION
        Explicitly loads shared credential, vault, converter and API helpers.
        Never executes source commands during discovery. Unsupported semantics require explicit
        reviewed replacements. Resuming re-reads Zabbix and rejects changed source snapshots.
    .PARAMETER PlanPath
        Redacted selection plan to resume; secrets and credentials are collected again.
    .EXAMPLE
        .\examples\Import-ZabbixHostsToWUG.ps1 -WhatIf
    .NOTES
        Requires PowerShell 5.1 and the example's shared functions.
    .LINK
        https://www.zabbix.com/documentation/current/en/manual/api
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$PlanPath)
    $resume = $null
    if ($PlanPath) { $resume = Read-ZabbixMigrationPlan $PlanPath }
    $url = if ($resume) { $resume.ApiUrl } else { Read-Host 'Zabbix HTTPS API URL (ending in api_jsonrpc.php)' }
    $apiUri = $null
    if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$apiUri) -or $apiUri.Scheme -ne 'https' -or
        $apiUri.UserInfo -or $apiUri.Query -or $apiUri.Fragment -or $apiUri.AbsolutePath -notlike '*/api_jsonrpc.php') { throw 'Enter a complete trusted HTTPS api_jsonrpc.php URL.' }
    $secureToken = Read-Host 'Zabbix API token' -AsSecureString
    $apiToken = [PSCredential]::new('api-token', $secureToken).GetNetworkCredential().Password
    $credentialSources = @{}
    $credentialChoices = @{}
    $stagedCredentials = [System.Collections.Generic.List[object]]::new()
    $plans = [System.Collections.Generic.List[object]]::new()
    try {
        if ($secureToken.Length -eq 0) { throw 'A Zabbix API token is required.' }
        $zabbixVersion = [version](Invoke-ZabbixExampleRequest -Method 'apiinfo.version' -Parameters @{} -Anonymous)
        if ($zabbixVersion -lt [version]'6.0' -or $zabbixVersion -ge [version]'7.5') { throw 'Supported Zabbix versions are 6.0-7.4.' }
        $globalMacros = @(Invoke-ZabbixExampleRequest -Method 'usermacro.get' -Parameters @{
            globalmacro = $true; output = @('macro', 'value', 'type')
        })
        $resumeIds = @()
        if ($resume) { $resumeIds = @($resume.Hosts.HostId) }
        $hosts = @(Select-ZabbixMigrationHosts -ResumeHostIds $resumeIds)
        if ($hosts.Count -eq 0) { Write-Warning 'Cancelled before WUG connection or writes.'; return }
        if ($resume -and $hosts.Count -ne $resumeIds.Count) { throw 'Some saved hosts are no longer accessible.' }
        foreach ($hostInfo in $hosts) {
            if ([string]$hostInfo.hostid -notmatch '^[0-9]+$' -or -not $hostInfo.host -or -not $hostInfo.name) {
                throw 'Zabbix returned an invalid host identity.'
            }
            if ($hostInfo.status -ne '0') { throw "Host '$($hostInfo.host)' is disabled." }
            $interfaces = @($hostInfo.interfaces | Where-Object { $_.main -eq '1' } | Sort-Object type)
            if ($interfaces.Count -eq 0) { throw "Host '$($hostInfo.host)' has no primary interface. Configure a WUG target address first." }
            $target = $interfaces[0]
            if ($interfaces.Count -gt 1) {
                $rows = @($interfaces | ForEach-Object { [PSCustomObject]@{ id = $_.interfaceid; name = "type $($_.type), $($_.ip)"; Interface = $_ } })
                $selected = Select-ZabbixMigrationRows -Rows $rows -Label "Choose one WUG target interface for $($hostInfo.host)"
                if ($selected -is [string] -or @($selected).Count -ne 1) { throw 'Select exactly one target interface.' }
                $target = $selected[0].Interface
            }
            $ip = $null
            if ($target.useip -ne '1' -or -not [System.Net.IPAddress]::TryParse([string]$target.ip, [ref]$ip) -or
                $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                throw 'The WUG device-template helper requires a literal IPv4 target. DNS/IPv6 target migration remains blocked.'
            }
            $templates = @(Get-ZabbixMigrationTemplates -Roots @($hostInfo.parentTemplates))
            if ($globalMacros.Count -gt 0) {
                # Globals are fallback only; an inherited macro name is not overwritten.
                $inheritedNames = @($templates | ForEach-Object { $_.macros } | Select-Object -ExpandProperty macro -Unique)
                $globals = @($globalMacros | Where-Object { $_.macro -notin $inheritedNames })
                $templates += [PSCustomObject]@{ host = 'Global macro fallback'; macros = $globals }
            }
            $items = @(Invoke-ZabbixExampleRequest -Method 'item.get' -Parameters @{
                hostids = @($hostInfo.hostid); output = 'extend'; selectPreprocessing = 'extend'
            })
            $triggers = @(Invoke-ZabbixExampleRequest -Method 'trigger.get' -Parameters @{
                hostids = @($hostInfo.hostid); output = 'extend'; expandExpression = $true; selectDependencies = @('triggerid')
            })
            $rules = @(Invoke-ZabbixExampleRequest -Method 'discoveryrule.get' -Parameters @{ hostids = @($hostInfo.hostid); output = @('itemid', 'status') })
            $web = @(Invoke-ZabbixExampleRequest -Method 'httptest.get' -Parameters @{
                hostids = @($hostInfo.hostid); output = 'extend'; selectSteps = 'extend'
            })
            $primarySnmp = @($interfaces | Where-Object { $_.type -eq '2' -and $_.ip -eq $target.ip })
            $primarySnmpId = if ($primarySnmp.Count -eq 1) { [string]$primarySnmp[0].interfaceid } else { 'none' }
            $profile = ConvertTo-ZabbixMigrationProfile -HostInfo $hostInfo -Items $items -Triggers $triggers -Rules $rules -WebScenarios $web `
                -SnmpInterfaceId $primarySnmpId
            foreach ($item in $items) {
                if ($item.type -notin @('1', '4', '6', '20')) { continue }
                $itemInterface = @($interfaces | Where-Object {
                    $_.interfaceid -eq $item.interfaceid -and $_.type -eq '2' -and $_.useip -eq '1' -and $_.ip -eq $target.ip
                })
                if ($itemInterface.Count -ne 1) {
                    $id = Get-ZabbixDefinitionId "$($hostInfo.host)|$($item.itemid)"
                    $definition = @($profile.Definitions | Where-Object { $_.Id -eq $id })[0]
                    $definition.Status = 'Deferred'; $definition.Candidate = $null
                    $definition.Reasons = @('Item SNMP interface differs from the primary SNMP interface at the chosen WUG target.')
                }
            }
            $snapshot = @($profile.Definitions | Sort-Object Id | ForEach-Object {
                [ordered]@{ Id = $_.Id; Status = $_.Status
                    Config = $(if ($_.Candidate) { Get-ZabbixMonitorFingerprint $_.Candidate.Template } else { '' })
                    Interval = $(if ($_.Candidate) { "$($_.Candidate.PollingIntervalSeconds)|$($_.Candidate.PollingIntervalMinutes)" } else { '' })
                }
            })
            $fingerprint = Get-ZabbixDefinitionId (ConvertTo-Json -InputObject ([ordered]@{
                Definitions = $snapshot; Target = "$($target.interfaceid)|$($target.ip)|$($target.port)"
                SnmpSecurity = @($primarySnmp | ForEach-Object {
                    "$($_.port)|$($_.details.version)|$($_.details.securitylevel)|$($_.details.authprotocol)|$($_.details.privprotocol)"
                })
            }) -Depth 20 -Compress)
            $plan = [PSCustomObject]@{
                Host = $hostInfo.host; HostId = [string]$hostInfo.hostid; Name = $hostInfo.name; Address = $ip.ToString()
                Port = 161; Prefix = "Zabbix $($apiUri.Authority) $($hostInfo.hostid) - "
                Fingerprint = $fingerprint; Profile = $profile; ExistingMonitors = @()
                DeviceId = $null; CredentialType = ''; AdditionalCredentialCandidates = @(); CredentialBindings = @()
            }
            $snmp = @($interfaces | Where-Object { $_.type -eq '2' -and $_.ip -eq $target.ip })
            $snmpCandidates = @($profile.Definitions | Where-Object {
                $_.Candidate -and $_.Candidate.Template.monitorTypeInfo.classId -in @('d6d02d69-a418-483a-93ea-20dd2af2d135', '2f300544-cba3-4341-9b05-2d1786f68e07')
            })
            if ($snmp.Count -ne 1 -and $snmpCandidates.Count -gt 0) {
                foreach ($definition in $snmpCandidates) {
                    $definition.Status = 'Deferred'; $definition.Candidate = $null
                    $definition.Reasons = @('A single primary SNMP interface at the selected WUG address is required.')
                }
            }
            if ($snmp.Count -eq 1 -and $snmpCandidates.Count -gt 0) {
                $plan.CredentialType = switch ([string]$snmp[0].details.version) { '1' { 'snmpV1' } '2' { 'snmpV2' } '3' { 'snmpV3' } default { throw 'Unknown SNMP version.' } }
                $port = 0
                if (-not [int]::TryParse([string]$snmp[0].port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Resolve SNMP port first.' }
                $plan.Port = $port
                $credentialSources[$plan.Host] = Get-ZabbixExampleCredentialSource -Details $snmp[0].details -HostMacros @($hostInfo.macros) -Templates $templates
                $plan.AdditionalCredentialCandidates += [PSCustomObject]@{
                    Host = $plan.Host; CredentialType = $plan.CredentialType; Label = 'SNMP polling'
                    SourceNames = @("interface $($snmp[0].interfaceid)"); Prefix = $plan.Prefix; SourceKey = $null
                }
            }
            $plan.AdditionalCredentialCandidates += @(Get-ZabbixMigrationCredentials -Plan $plan -Items $items `
                -HostMacros @($hostInfo.macros) -Templates $templates -WebScenarios $web)
            if ($resume) {
                $saved = @($resume.Hosts | Where-Object { $_.HostId -eq $plan.HostId })[0]
                if ($saved.Fingerprint -cne $fingerprint) { throw "Source changed for '$($plan.Host)'; create and review a new plan." }
                foreach ($definition in $profile.Definitions) {
                    if ($definition.Id -in @($saved.Selected) -and $definition.Candidate) { $definition.Status = 'Ready' }
                    elseif ($definition.Status -eq 'Ready') { $definition.Status = 'Skipped' }
                }
                $plan.ExistingMonitors = @($saved.Existing)
            }
            $plans.Add($plan)
        }
        $apiToken = $null
        foreach ($property in @('Name', 'Address')) {
            if (@($plans | Group-Object $property | Where-Object { $_.Count -gt 1 }).Count -gt 0) { throw "Ambiguous duplicate target $property." }
        }
        $plans | Select-Object Host, Address, @{n='Ready';e={@($_.Profile.Definitions | Where-Object { $_.Status -eq 'Ready' }).Count}},
            @{n='Review';e={@($_.Profile.Definitions | Where-Object { $_.Status -ne 'Ready' }).Count}},
            @{n='Credentials';e={$_.AdditionalCredentialCandidates.Count}} | Format-Table | Out-Host
        if ($WhatIfPreference) {
            [void]$PSCmdlet.ShouldProcess('WUG', 'Review and apply migration (no WUG connection/writes in preview)')
            # Only return explicitly redacted discovery metadata.
            foreach ($plan in $plans) {
                [PSCustomObject]@{ HostId = $plan.HostId; Address = $plan.Address
                    Definitions = @($plan.Profile.Definitions | Select-Object Id, Name, Status, Reasons)
                    Credentials = @($plan.AdditionalCredentialCandidates | Select-Object Label, CredentialType, SourceNames) }
            }
            return
        }
        Connect-WUGServer -ErrorAction Stop
        if (-not $global:WUGBearerHeaders -or -not $global:WhatsUpServerBaseURI) { throw 'WUG connection failed.' }
        if ($resume.WugUrl -and $resume.WugUrl.TrimEnd('/') -ine $global:WhatsUpServerBaseURI.TrimEnd('/')) {
            throw 'Saved replacement selections belong to a different WUG server; create a new plan.'
        }
        :review while ($true) {
            $action = Read-Host '[M] Review monitor alternatives, [X] Exclude monitors, [C] Review credentials, [S] Save redacted plan, [A] Apply, [B] Back to review, [Q] Cancel'
            switch ($action.ToUpperInvariant()) {
                'Q' { Write-Warning 'Cancelled; staged credentials were not written.'; return }
                'B' { continue review }
                'M' { Review-ZabbixMigrationMonitors -Plans $plans.ToArray(); continue review }
                'X' {
                    foreach ($plan in $plans) {
                        $rows = @($plan.Profile.Definitions | Where-Object { $_.Status -eq 'Ready' } |
                            ForEach-Object { [PSCustomObject]@{ id = $_.Id; name = $_.Candidate.Name; Definition = $_ } })
                        $selected = Select-ZabbixMigrationRows -Rows $rows -Label "Exclude approved monitors for $($plan.Host)"
                        if ($selected -isnot [string]) { foreach ($row in $selected) { $row.Definition.Status = 'Skipped' } }
                    }
                    continue review
                }
                'S' {
                    $path = Read-Host 'New plan JSON path'
                    Save-ZabbixMigrationPlan -Path $path -Plans $plans.ToArray() -ApiUrl $apiUri.AbsoluteUri
                    continue review
                }
                'C' {
                    foreach ($plan in $plans) {
                        if ((Read-Host "Add a credential type not detected for '$($plan.Host)' (e.g. a Windows credential for a WUG-native replacement)? [Y/N]") -ieq 'Y') {
                            $rows = @(@('snmpV1','snmpV2','snmpV3','ssh','windows','restapi','ado','aws','azure','redfish','vmware','jmx') |
                                ForEach-Object { [PSCustomObject]@{ id = $_; name = $_ } })
                            $selected = Select-ZabbixMigrationRows -Rows $rows -Label 'Choose one additional credential type'
                            if ($selected -isnot [string] -and @($selected).Count -eq 1) {
                                $type = $selected[0].id
                                $key = "$($plan.Host)|manual-$type"
                                if (-not $credentialSources.ContainsKey($key)) {
                                    $credentialSources[$key] = @{}
                                    $plan.AdditionalCredentialCandidates += [PSCustomObject]@{
                                        Host = $plan.Host; CredentialType = $type; SourceKey = $key
                                        AuthMode = $(if ($type -in @('vmware','jmx')) { 'ExistingOnly' } else { 'Basic' })
                                        Label = "Operator-selected $type credential"; SourceNames = @('Operator selection, not inferred from Zabbix')
                                        Prefix = "$($plan.Prefix)$type - "
                                    }
                                }
                            }
                            elseif ($selected -isnot [string]) { Write-Warning 'Choose one credential type; no candidates were added.' }
                        }
                        foreach ($candidate in $plan.AdditionalCredentialCandidates) {
                            $key = if ($candidate.SourceKey) { $candidate.SourceKey } else { $plan.Host }
                            if ($credentialChoices.ContainsKey($key)) { continue }
                            Write-Warning "$($plan.Host): $($candidate.Label); sources: $($candidate.SourceNames -join ', '). Confirm purpose; no secrets are displayed."
                            if ((Read-Host 'Use this credential candidate? [Y/N]') -ine 'Y') { continue }
                            $previous = @($credentialChoices.Values | Where-Object { $_.type -eq $candidate.CredentialType } | Select-Object -Unique)
                            $credential = $null
                            if ($previous.Count -gt 0 -and (Read-Host "Reuse the last reviewed $($candidate.CredentialType) credential across this host too? [Y/N]") -ieq 'Y') {
                                $credential = $previous[-1]
                            }
                            else {
                                $credential = Select-WugExampleCredential -Plan $candidate -DeferCreation
                                if ($credential -and $credential.Fields) { $stagedCredentials.Add($credential) }
                            }
                            if (-not $credential) { continue }
                            $credentialChoices[$key] = $credential
                            $assign = (Read-Host "Assign this $($candidate.CredentialType) credential to WUG device '$($plan.Host)'? [Y/N]") -ieq 'Y'
                            if ($assign) {
                                if (@($plan.CredentialBindings | Where-Object { $_.Type -eq $candidate.CredentialType }).Count -gt 0) {
                                    Write-Warning "A $($candidate.CredentialType) credential is already selected for this device. This additional candidate stays library-only."
                                }
                                else { $plan.CredentialBindings += [PSCustomObject]@{ Key = $key; Type = $candidate.CredentialType } }
                            }
                        }
                    }
                    continue review
                }
                'A' {
                    $ready = $true
                    foreach ($plan in $plans) {
                        $approved = @($plan.Profile.Definitions | Where-Object { $_.Status -eq 'Ready' })
                        if ($approved.Count -eq 0 -and $plan.ExistingMonitors.Count -eq 0) {
                            Write-Warning "No approved monitors for '$($plan.Host)'. Use M to review alternatives."
                            $ready = $false
                        }
                        $requiresSnmp = @($approved | Where-Object {
                            $_.Candidate.Template.monitorTypeInfo.classId -in @('d6d02d69-a418-483a-93ea-20dd2af2d135', '2f300544-cba3-4341-9b05-2d1786f68e07')
                        }).Count -gt 0
                        if ($requiresSnmp -and @($plan.CredentialBindings | Where-Object { $_.Type -eq $plan.CredentialType }).Count -eq 0) {
                            Write-Warning "Approve an SNMP credential assignment for '$($plan.Host)' using C."
                            $ready = $false
                        }
                    }
                    if ($ready) { break review }
                    continue review
                }
                default { Write-Warning 'Choose M, X, C, S, A, B or Q.' }
            }
        }
        foreach ($plan in $plans) {
            $existing = Find-WugExampleDevice $plan
            if ($existing) { $plan.DeviceId = $existing.id }
            if ($plan.ExistingMonitors.Count -gt 0) {
                $library = Get-WUGZabbixLibraryTemplates
                $assignmentIntervals = @{}
                foreach ($monitor in $plan.ExistingMonitors) {
                    $assignmentKey = "$($monitor.Type)|$($monitor.Id)"
                    if ($assignmentIntervals.ContainsKey($assignmentKey) -and $assignmentIntervals[$assignmentKey] -ne $monitor.Interval) {
                        throw 'Reviewed replacements disagree on the polling interval for the same monitor; review a consistent selection.'
                    }
                    $assignmentIntervals[$assignmentKey] = $monitor.Interval
                    $matches = @($library.Values | Where-Object { $_.id -eq $monitor.Id -and $_.monitorTypeInfo.baseType -eq $monitor.Type })
                    if ($matches.Count -ne 1 -or (Get-ZabbixMonitorFingerprint $matches[0]) -cne $monitor.Fingerprint) {
                        throw 'A selected existing replacement monitor is no longer available; review again.'
                    }
                }
            }
        }
        $library = Get-WUGZabbixLibraryTemplates
        $supported = (Invoke-WugExampleRequest -Path 'monitors/-/config/supported-types?type=all&includeCoreMonitorTypes=true').data
        $requestedNames = @{}
        foreach ($plan in $plans) {
            foreach ($definition in @($plan.Profile.Definitions | Where-Object { $_.Status -eq 'Ready' })) {
                $template = $definition.Candidate.Template
                $info = $template.monitorTypeInfo
                if (@($supported | Where-Object { $_.classId -eq $info.classId -and $_.baseType -eq $info.baseType }).Count -eq 0) {
                    throw "The connected WUG server does not advertise monitor class '$($info.classId)'."
                }
                $key = "$($info.baseType)|$($plan.Prefix)$($template.name)".ToLowerInvariant()
                $fingerprint = Get-ZabbixMonitorFingerprint $template
                if (($library.ContainsKey($key) -and (Get-ZabbixMonitorFingerprint $library[$key]) -cne $fingerprint) -or
                    ($requestedNames.ContainsKey($key) -and $requestedNames[$key] -cne $fingerprint)) {
                    throw 'A planned monitor name/configuration conflict exists. Nothing was written; review it first.'
                }
                $requestedNames[$key] = $fingerprint
            }
        }
        $pendingCredentials = @{}
        foreach ($credential in $credentialChoices.Values) {
            if ($credential.id) {
                $current = (Invoke-WugExampleRequest -Path ("credentials/" + [uri]::EscapeDataString([string]$credential.id) + '?view=basic')).data
                if ($current.id -ne $credential.id -or $current.type -ne $credential.type -or $current.name -ne $credential.name) {
                    throw 'A selected WUG credential changed; reselect before applying.'
                }
            }
            elseif ($pendingCredentials.ContainsKey($credential.name)) {
                if (-not [object]::ReferenceEquals($pendingCredentials[$credential.name], $credential)) {
                    throw "Distinct staged credentials share the name '$($credential.name)'; choose unique names or explicitly reuse one candidate."
                }
            }
            else { $pendingCredentials[$credential.name] = $credential }
        }
        $plans | Select-Object Host, DeviceId, @{n='CreateDevice';e={-not $_.DeviceId}},
            @{n='Monitors';e={@($_.Profile.Definitions | Where-Object { $_.Status -eq 'Ready' }).Count + $_.ExistingMonitors.Count}},
            @{n='Assignments';e={$_.CredentialBindings.Count}} | Format-Table | Out-Host
        $credentialChoices.Values | Select-Object name, type, @{n='Create';e={-not $_.id}} | Format-Table | Out-Host
        Write-Warning 'This is the final write approval. Source commands were not executed during discovery. New monitors may execute later on the WUG poller. Writes are not transactional.'
        if ((Read-Host 'Type APPLY to save credentials, create devices/monitors and assign approved objects') -cne 'APPLY') { return }
        if (-not $PSCmdlet.ShouldProcess('WUG', 'Apply reviewed migration')) { return }
        $resolvedCredentials = @{}
        foreach ($key in @($credentialChoices.Keys)) {
            $credential = $credentialChoices[$key]
            $identity = if ($credential.id) { "id:$($credential.id)" } else { "name:$($credential.name)" }
            if (-not $resolvedCredentials.ContainsKey($identity)) { $resolvedCredentials[$identity] = Apply-ZabbixMigrationCredential $credential }
            $credentialChoices[$key] = $resolvedCredentials[$identity]
        }
        foreach ($plan in $plans) {
            $receipts = @(Invoke-WUGZabbixProfileImport -Profiles @($plan.Profile) -NamePrefix $plan.Prefix `
                -IncludeMigrationAlternatives -Confirm:$false -ErrorAction Stop)
            if (-not $plan.DeviceId) {
                $created = Add-WUGDeviceTemplate -displayName $plan.Name -DeviceAddress $plan.Address -Hostname $plan.Host `
                    -SNMPPort $plan.Port -Brand 'Zabbix' -NoDefaultActiveMonitor -Confirm:$false -ErrorAction Stop
                if ($created.successful -ne 1 -or $created.errors -or @($created.idMap).Count -ne 1 -or -not $created.idMap[0].resultId) { throw 'Device creation not confirmed.' }
                $plan.DeviceId = $created.idMap[0].resultId
            }
            $path = 'devices/' + [uri]::EscapeDataString([string]$plan.DeviceId)
            foreach ($binding in $plan.CredentialBindings) {
                $credential = $credentialChoices[$binding.Key]
                $assigned = Invoke-WugExampleRequest -Path "$path/credentials/-" -Method PUT -Body ([string]$credential.id)
                if ($assigned.success -ne $true) { throw 'Credential assignment not confirmed.' }
                $readback = (Invoke-WugExampleRequest -Path "$path/credentials/-?view=basic&type=all").data
                if (@($readback | Where-Object { $_.id -eq $credential.id }).Count -ne 1) { throw 'Credential read-back failed.' }
            }
            $desired = @($plan.ExistingMonitors)
            foreach ($receipt in $receipts) {
                $candidate = @($plan.Profile.Definitions | Where-Object { $_.Candidate -and $plan.Prefix + $_.Candidate.Name -ceq $receipt.Name })[0].Candidate
                $interval = if ($receipt.BaseType -eq 'active') { $candidate.PollingIntervalSeconds } else { $candidate.PollingIntervalMinutes }
                $desired += [PSCustomObject]@{ Id = $receipt.MonitorId; Type = $receipt.BaseType; Interval = $interval }
            }
            $desired = @($desired | Group-Object { "$($_.Type)|$($_.Id)" } | ForEach-Object { $_.Group[0] })
            $assigned = @(Get-WugExamplePages -Path "$path/monitors/-?type=all&view=basic&limit=250")
            $createdAssignments = 0
            foreach ($monitor in $desired) {
                if (@($assigned | Where-Object { $_.type -eq $monitor.Type -and $_.monitorTypeId -eq $monitor.Id }).Count -gt 0) { continue }
                $body = @{ type = $monitor.Type; monitorTypeId = [string]$monitor.Id; enabled = $true; isGlobal = $true }
                if ($monitor.Type -eq 'active') { $body['active'] = @{ pollingIntervalSeconds = $monitor.Interval } }
                elseif ($monitor.Type -eq 'performance') { $body['performance'] = @{ pollingIntervalMinutes = $monitor.Interval } }
                $response = Invoke-WugExampleRequest -Path "$path/monitors/-" -Method POST -Body $body
                if ($response.data.successful -ne 1) { throw 'Monitor assignment failed.' }
                $createdAssignments++
            }
            $confirmed = @(Get-WugExamplePages -Path "$path/monitors/-?type=all&view=basic&limit=250")
            foreach ($monitor in $desired) {
                if (@($confirmed | Where-Object { $_.type -eq $monitor.Type -and $_.monitorTypeId -eq $monitor.Id }).Count -eq 0) { throw 'Final monitor reconciliation failed.' }
            }
            [PSCustomObject]@{
                HostId = $plan.HostId; DeviceId = $plan.DeviceId
                CreatedLibraryMonitors = @($receipts | Where-Object { $_.Action -eq 'Created' }).Count
                CreatedAssignments = $createdAssignments; AssignedMonitors = $desired.Count
                AssignedCredentials = $plan.CredentialBindings.Count
                BlockedDefinitions = @($plan.Profile.Definitions | Where-Object { $_.Status -ne 'Ready' }).Count
                ReviewedReplacements = $plan.ExistingMonitors.Count
                AssignmentValidation = 'ReadBackVerified'; LiveValidation = 'NotRun'
            }
        }
    }
    finally {
        $apiToken = $null
        $secureToken.Dispose()
        foreach ($source in $credentialSources.Values) { foreach ($value in $source.Values) { $value.Dispose() } }
        foreach ($credential in $stagedCredentials) {
            foreach ($value in $credential.Fields.Values) { $value.Dispose() }
        }
        $credentialSources.Clear()
        $credentialChoices.Clear()
        $items = $null; $hosts = $null; $templates = $null; $web = $null; $globalMacros = $null
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAM6t00uoGN/6rq
# JktWw51gnUJ3EQsFvvJXjGAEH/sOkaCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCC4
# 7DxOvewp+gvLobObLnu8GJcr9W5d+FzRXQVgLyW7IzANBgkqhkiG9w0BAQEFAASC
# AgDhFc2aflm15xnP/VVD/Oc3iBXC+xo9gHftOXQbV4FrwdGXjKR4Ei491efMIXX9
# InR3MWeavW9V9fuC8OCK7saDWutK2w9EuIls8GvUXK5bCeWVQYtPW69FCM1PGQu7
# vTj5vFNAhRDMq3aFr9z933dBLqE80SxFLOermHPNa00cLkOaEHscedh1df6w7GVA
# xzTndhTWGlSqznegIMrWrlX9p2Sjs1Usq02Q2iFUlGjaG2s8vOwPWL+rzvO67Piq
# 0Iat4U++Vr2KxnyWRpR4TF4RqcTxnutEAKOfIUeW7jGLlfG1MHlGIQevn4LzHQwW
# kja6zmYnVJ+ztzBQ8/lgC3iTfgoM2CBV/gMwJcnUoHEasJCI9bfHrlHyQkBXGCM1
# UDAxH4aiVHwpKuW3aq6MozH9hmCBoFu3dw0COJjG+5qGErM//nyXMNY6TsyThIEO
# b1Qrax5+PEGbnPEmPPBglvOqWY61gK98nhNdnnbITtRMzIUxUgPvVDo6pTiqi81V
# WOBL1u9TsrEdLUEWoa3NEWQ2eYrYvRP9BTL9JEctr6s7y5rRpexkm48X9SJDEU8S
# p/VjYVJM/cnyqm06AuZJQrxnIj7P9C/G2ZW2bF8FMsPdPvzlMTVt8XRNrrSymcrU
# 5/68wqepNWxq/ahf11jhDN+QbsIfKJeMTn1PrkUnv7C9fKGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMTEwMjA0MTVaMC8GCSqGSIb3DQEJBDEiBCCjpGJ9zpe0
# NecKC29tKyAenee6gR5IbmdBfSlwfhtKXTANBgkqhkiG9w0BAQEFAASCAgBc93vn
# 0QhRRH3sEy0FZ3RrPt71lXBlJS0ceAKdPn5hSOvkXOuI7bR34wN2jDlVdlxpDTpP
# pXxUzZXQu2AGBKJrJKmj0ZEXLI7jH8HnxxASVsuHs3xYXPjWZ0OyzzNouhEx+hwn
# td4oBxiA2EBREWmWyjHyxkX4WCFwhQIb1UODYOrCs3nv+4Xi919IFwYLLqH3Bsby
# nr6RsSrVkSQQ2d9drMmsUV22U+Esr+ipzSc0BHq3l7D8p1J8eitQnYijPGpfwLcK
# fuZS6a7g2xOm9aQZl2sIYyoy9lUQ1dphRnt2vWJzzOJhkpOqeZYDHFBHxZN35Ns/
# ZRsszPqEH7F8rReBFyXKFgSSmhHsN+tG8Mi1jswIPAb3Pu3oLFh84bwLtH9zdeOi
# OSAu3gpZ3hpysIPjHUYhFBqBz6bpwH/4JA75QDXobSh7sozeULh3wwh93mNdB1LR
# fsXTRzAl6IlwtP3AKpcR3/lYPciM13j33CkFpuX19CC8ixaLvkx/AExppSUNGgo5
# J5xzXjoxfPd4UU0LurumCZKdwId7JRF0KaCT+vCz4ieA6v+t3KdeFCGFXLmAqts8
# Dcl9Cr4viouQJKSNdsxsPWhYvSgFyTSJ60Dt1pmRF1RON2ivHPKiu6RN04Vwixrd
# 5HX5qqafEB/E6KQmsQwBgEgvOPPLUAcqzipJZQ==
# SIG # End signature block
