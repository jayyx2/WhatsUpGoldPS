$converterDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $converterDir 'ZabbixConversionCommon.ps1')
. (Join-Path $converterDir 'ZabbixTemplateResolution.ps1')
. (Join-Path $converterDir 'ZabbixSnmpMappings.ps1')
. (Join-Path $converterDir 'ZabbixWugImport.ps1')

function ConvertFrom-ZabbixXmlNode {
    param([System.Xml.XmlElement]$Node, [int]$Depth = 0)
    if ($Depth -gt 64) { throw 'XML input exceeds the maximum nesting depth (64).' }
    $children = @($Node.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })
    if ($children.Count -eq 0) { return $Node.InnerText }
    $listNames = @('templates', 'items', 'discovery_rules', 'item_prototypes', 'trigger_prototypes',
        'triggers', 'macros', 'preprocessing', 'groups', 'template_groups', 'tags', 'valuemaps',
        'mappings', 'conditions', 'graphs', 'graph_prototypes', 'dependencies', 'parameters',
        'host_prototypes', 'overrides', 'applications', 'application_prototypes', 'graph_items',
        'screens', 'screen_items', 'lld_macro_paths', 'query_fields', 'fields', 'widgets', 'pages', 'operations',
        'value_maps', 'dashboards')
    if ($Node.LocalName -cin $listNames) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($child in $children) { $list.Add((ConvertFrom-ZabbixXmlNode $child ($Depth + 1))) }
        return ,$list.ToArray()
    }
    $map = New-ZabbixMap
    foreach ($child in $children) {
        if ($map.ContainsKey($child.LocalName)) { throw "Duplicate XML field '$($child.LocalName)' in '$($Node.LocalName)'." }
        $map.Add($child.LocalName, (ConvertFrom-ZabbixXmlNode $child ($Depth + 1)))
    }
    return ,$map
}

function Read-ZabbixExport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer) { throw 'Select a single template export file, not a directory.' }
    if ($file.Length -gt 16777216) { throw 'Template export exceeds the 16 MiB file limit.' }
    $text = [System.IO.File]::ReadAllText($file.FullName)
    switch ($file.Extension.ToLowerInvariant()) {
        '.xml' {
            $settings = [System.Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $settings.MaxCharactersInDocument = 16777216
            $stringReader = [System.IO.StringReader]::new($text)
            $reader = [System.Xml.XmlReader]::Create($stringReader, $settings)
            try {
                $xml = [System.Xml.XmlDocument]::new()
                $xml.XmlResolver = $null
                $xml.Load($reader)
                if ($xml.DocumentElement.LocalName -cne 'zabbix_export') { throw 'Not a Zabbix export: missing zabbix_export root.' }
                $data = New-ZabbixMap
                $data.Add('zabbix_export', (ConvertFrom-ZabbixXmlNode $xml.DocumentElement))
            }
            finally { $reader.Dispose(); $stringReader.Dispose() }
        }
        '.json' { $data = ConvertTo-ZabbixData (ConvertFrom-Json -InputObject $text -ErrorAction Stop) }
        { $_ -in '.yaml', '.yml' } { $data = Read-ZabbixYaml -Text $text -Source $file.FullName }
        default { throw "Unsupported input extension '$($file.Extension)'. Use YAML, XML or JSON." }
    }
    if ($data -isnot [System.Collections.IDictionary] -or -not $data.ContainsKey('zabbix_export')) {
        throw 'Not a Zabbix export: missing zabbix_export root.'
    }
    $export = $data['zabbix_export']
    if ($export -isnot [System.Collections.IDictionary]) { throw 'zabbix_export must be a mapping.' }
    $version = [string]$export['version']
    if ($version -notin @('5.0', '5.2', '5.4', '6.0', '6.2', '6.4', '7.0', '7.2', '7.4')) {
        throw "Unsupported Zabbix export version '$version'."
    }
    if (-not $export.ContainsKey('templates') -or $export['templates'] -isnot [array] -or $export['templates'].Count -eq 0) {
        throw 'zabbix_export.templates must be a nonempty sequence.'
    }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    [PSCustomObject]@{ Path = $file.FullName; Sha256 = $hash; Version = $version; Data = $export }
}

function Protect-ZabbixSource {
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($Depth -gt 64) { throw 'Source data exceeds the maximum nesting depth (64).' }
    if ($Value -is [System.Collections.IDictionary]) {
        $map = New-ZabbixMap
        foreach ($key in $Value.Keys) {
            if ($key -match '(?i)password|passwd|secret|community|token|authorization|privatekey|passphrase' -or
                ($key -eq 'value' -and $Value.ContainsKey('macro'))) { $map.Add($key, '[REDACTED]') }
            elseif ($key -in @('description', 'url', 'headers', 'posts', 'params', 'script', 'command')) {
                $map.Add($key, '[OMITTED: free-form source content]')
            }
            else { $map.Add($key, (Protect-ZabbixSource $Value[$key] ($Depth + 1))) }
        }
        return ,$map
    }
    if ($Value -is [array]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $list.Add((Protect-ZabbixSource $item ($Depth + 1))) }
        return ,$list.ToArray()
    }
    return $Value
}

function New-ZabbixDefinition {
    param([string]$Template, [string]$Kind, [string]$Location, $Source)
    [PSCustomObject][ordered]@{
        Id = Get-ZabbixDefinitionId "$Template|$Kind|$Location"
        Kind = $Kind
        Location = $Location
        Name = [string]$Source['name']
        Status = 'Deferred'
        Reasons = @()
        Source = Protect-ZabbixSource $Source
        Candidate = $null
        Validation = 'OfflineOnly'
    }
}

function ConvertTo-ZabbixSnmpCandidate {
    param($Definition, $Item, [string]$TemplateName, [bool]$Prototype)
    if ($Item['name'] -isnot [string] -or -not $Item['name'].Trim() -or
        $Item['key'] -isnot [string] -or -not $Item['key'].Trim()) {
        Set-ZabbixDefinitionState $Definition 'Invalid' 'ITEM_IDENTITY' 'Items require nonempty string name and key fields.'
        return
    }
    $type = [string]$Item['type']
    if ([string]$Item['name'] -match '\{\$' -or [string]$Item['key'] -match '\{\$' -or [string]$Item['delay'] -match '\{\$') {
        Set-ZabbixDefinitionState $Definition 'NeedsInput' 'ITEM_MACRO' 'An item name, key or polling interval contains an unresolved user macro.'
        return
    }
    if ($type -in @('SNMP_TRAP', '17')) {
        ConvertTo-ZabbixTrapCandidate $Definition $Item $TemplateName $Prototype
        return
    }
    if ($type -notin @('SNMP_AGENT', '1', '4', '6')) {
        Set-ZabbixDefinitionState $Definition 'Unsupported' 'ITEM_TYPE' "Item type '$type' is outside SNMP polling support."
        return
    }
    $oid = [string]$Item['snmp_oid']
    if ($oid -match '^get\[(\s*\.?\d+(?:\.\d+)+\s*)\]$') { $oid = $Matches[1].Trim() }
    if ($oid -match '\{\$') {
        Set-ZabbixDefinitionState $Definition 'NeedsInput' 'OID_MACRO' 'The OID contains an unresolved user macro.'
        return
    }
    if ($Prototype -or $oid -match '\{#') {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'TABLE_INSTANCE' 'Per-row performance monitoring requires live discovery of the complete SNMP index.'
        return
    }
    if ($oid -notmatch '^\.?[0-9]+(?:\.[0-9]+)+$') {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'OID_EXPRESSION' 'Only a concrete numeric OID or single get[OID] is currently translatable.'
        return
    }
    $arcs = $oid.TrimStart('.').Split('.')
    $validArcs = $true
    foreach ($arc in $arcs) {
        $number = [uint32]0
        if (-not [uint32]::TryParse($arc, [ref]$number)) { $validArcs = $false; break }
    }
    if (-not $validArcs -or $arcs.Count -lt 3 -or $arcs[0] -notmatch '^[012]$' -or
        ($arcs[0] -ne '2' -and [uint32]$arcs[1] -gt 39)) {
        Set-ZabbixDefinitionState $Definition 'Invalid' 'OID_INVALID' 'Invalid numeric SNMP object identifier.'
        return
    }
    $valueType = [string]$Item['value_type']
    if ($valueType -notin @('', 'FLOAT', 'UNSIGNED', '0', '3')) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'NON_NUMERIC' "Value type '$valueType' is not a numeric performance collector."
        return
    }
    if (@($Item['preprocessing']).Count -gt 0 -and $Item['preprocessing']) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'PREPROCESSING' 'Preprocessing must be mapped and verified before exporting this collector; raw values would change its meaning.'
        return
    }
    if ($Item.ContainsKey('delta') -and [string]$Item['delta'] -notin @('', '0', 'AS_IS')) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'DELTA' 'Legacy delta processing has not been mapped.'
        return
    }
    $delay = [string]$Item['delay']
    if (-not $delay) { $delay = '1m' }
    if ($delay -match '^([1-9][0-9]*)([smhd]?)$') {
        $amount = [decimal]0
        if (-not [decimal]::TryParse($Matches[1], [ref]$amount) -or $amount -gt 86400) {
            Set-ZabbixDefinitionState $Definition 'Deferred' 'POLLING_PRECISION' 'Polling interval exceeds the supported WUG assignment range.'
            return
        }
        $unit = $Matches[2]
        $factor = switch ($unit) { 'm' { 60 } 'h' { 3600 } 'd' { 86400 } default { 1 } }
        $seconds = $amount * $factor
    }
    else {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'POLLING_SCHEDULE' "Polling schedule '$delay' requires macro/schedule resolution."
        return
    }
    if ($seconds -lt 60 -or $seconds -gt 86400 -or $seconds % 60 -ne 0) {
        Set-ZabbixDefinitionState $Definition 'Deferred' 'POLLING_PRECISION' 'WUG performance assignments require whole minutes between 1 and 1440; no rounding was applied.'
        return
    }
    $numericOid = $oid.TrimStart('.')
    # Keep the complete instance in the OID rather than guessing table-index boundaries.
    $Definition.Candidate = [PSCustomObject][ordered]@{
        ItemType = 'PerformanceMonitor'
        MonitorType = 'Snmp'
        Name = "$TemplateName - $($Item['name'])"
        PollingIntervalMinutes = [int]($seconds / 60)
        Units = [string]$Item['units']
        MonitorParams = [ordered]@{ SnmpOID = $numericOid; SnmpInstance = ''; SnmpUseRawValues = '1' }
        Template = [ordered]@{
            templateId = $Definition.Id
            name = "$TemplateName - $($Item['name'])"
            monitorTypeInfo = [ordered]@{ classId = '2f300544-cba3-4341-9b05-2d1786f68e07'; baseType = 'performance' }
            propertyBags = @(
                [ordered]@{ name = 'SNMP:OID'; value = $numericOid }
                [ordered]@{ name = 'SNMP:Instance'; value = '' }
                [ordered]@{ name = 'SNMP:UseRawValues'; value = '1' }
                [ordered]@{ name = 'SNMP:Retries'; value = '1' }
                [ordered]@{ name = 'SNMP:Timeout'; value = '3' }
            )
        }
    }
    Set-ZabbixDefinitionState $Definition 'Ready' 'DIRECT_SNMP' 'Direct raw numeric collector; property bags match the module. Live WUG collection remains unvalidated.'
}

function ConvertFrom-ZabbixExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Export,
        [string]$TemplateName,
        $Catalog,
        [System.Collections.IDictionary]$MacroValues,
        [System.Collections.IDictionary]$TableDiscovery
    )
    if ($null -eq $Catalog) { $Catalog = New-ZabbixTemplateCatalog @($Export) }
    $profiles = [System.Collections.Generic.List[object]]::new()
    foreach ($template in $Export.Data['templates']) {
        if ($template -isnot [System.Collections.IDictionary] -or $template['template'] -isnot [string] -or
            -not $template['template'].Trim()) { throw 'Every template requires a nonempty string template identity.' }
        $identity = [string]$template['template']
        if ($TemplateName -and $identity -cne $TemplateName) { continue }
        $resolution = Resolve-ZabbixTemplate $Catalog $Export.Version $identity
        $macros = Get-ZabbixMacroValues $resolution.Template $MacroValues
        $resolvedTemplate = Expand-ZabbixTemplateFields $resolution.Template $macros
        $definitions = [System.Collections.Generic.List[object]]::new()
        $context = [PSCustomObject]@{ Lineage = $resolution.Lineage; Items = @($resolvedTemplate['items']); TableDiscovery = $TableDiscovery }
        $hasLinks = $resolution.Issues.Count -gt 0
        Add-ZabbixDefinitions -Source $resolvedTemplate -Definitions $definitions -Template $identity -HasLinks $hasLinks -Context $context
        $globals = New-ZabbixMap
        foreach ($key in $Export.Data.Keys) {
            if ($key -cne 'templates') { $globals.Add($key, $Export.Data[$key]) }
        }
        $globals = Expand-ZabbixTemplateFields $globals $macros
        Add-ZabbixDefinitions -Source $globals -Definitions $definitions -Template $identity -Location 'export.' -HasLinks $hasLinks -Context $context
        $dependencyGlobals = [System.Collections.Generic.List[object]]::new()
        foreach ($dependency in $resolution.GlobalExports) {
            if ($dependency.Path -eq $Export.Path) { continue }
            $dependencyGlobal = New-ZabbixMap
            foreach ($key in $dependency.Data.Keys) {
                if ($key -cne 'templates') { $dependencyGlobal.Add($key, $dependency.Data[$key]) }
            }
            $dependencyGlobal = Expand-ZabbixTemplateFields $dependencyGlobal $macros
            Add-ZabbixDefinitions -Source $dependencyGlobal -Definitions $definitions -Template $identity -Location "dependency[$($dependencyGlobals.Count)]." -HasLinks $hasLinks -Context $context
            $dependencyGlobals.Add([PSCustomObject]@{ Path = $dependency.Path; Data = Protect-ZabbixSource $dependencyGlobal })
        }
        $counts = [ordered]@{}
        foreach ($status in @('Ready', 'NeedsInput', 'Deferred', 'Unsupported', 'Disabled', 'Invalid')) {
            $counts[$status] = @($definitions | Where-Object { $_.Status -eq $status }).Count
        }
        $profiles.Add([PSCustomObject][ordered]@{
            SchemaVersion = '0.2'
            ConverterVersion = '0.2.0'
            Template = $identity
            Source = [ordered]@{ Path = $Export.Path; Sha256 = $Export.Sha256; Version = $Export.Version }
            Completion = if ($definitions.Count -eq 0) { 'Empty' } elseif ($counts.Ready -eq $definitions.Count) { 'ConvertedOffline' } else { 'Partial' }
            Validation = 'OfflineOnly'
            CredentialRequirement = 'Bind an existing SNMP credential when deploying; no credentials are exported.'
            Counts = $counts
            ResolutionIssues = $resolution.Issues
            DependencySources = $resolution.Sources
            Definitions = $definitions.ToArray()
            SourceTemplate = Protect-ZabbixSource $template
            SourceGlobals = Protect-ZabbixSource $globals
            DependencyGlobals = $dependencyGlobals.ToArray()
        })
    }
    if ($profiles.Count -eq 0) { throw "Template '$TemplateName' was not found (template selection is case-sensitive)." }
    return ,$profiles.ToArray()
}

function Add-ZabbixDefinitions {
    param(
        $Source,
        [System.Collections.Generic.List[object]]$Definitions,
        [string]$Template,
        [string]$Location = '',
        [bool]$HasLinks = $false,
        [bool]$ParentDisabled = $false,
        [int]$Depth = 0,
        $Context,
        $Rule,
        $ItemContext
    )
    if ($Depth -gt 64) { throw 'Definition nesting exceeds the maximum depth (64).' }
    foreach ($collection in @('items', 'triggers', 'discovery_rules', 'item_prototypes',
        'trigger_prototypes', 'host_prototypes', 'graphs', 'graph_prototypes', 'dashboards')) {
        $entries = $Source[$collection]
        if ($null -eq $entries -or $entries -ceq '') { continue }
        if ($entries -isnot [array]) { throw "Expected a sequence at '$Location$collection'." }
        for ($index = 0; $index -lt $entries.Count; $index++) {
            $entry = $entries[$index]
            if ($entry -isnot [System.Collections.IDictionary]) { throw "Expected a mapping at '$Location${collection}[$index]'." }
            $path = "$Location${collection}[$index]"
            $kind = switch ($collection) { 'items' { 'Item' } 'triggers' { 'Trigger' } 'discovery_rules' { 'DiscoveryRule' } default { $collection } }
            $definition = New-ZabbixDefinition $Template $kind $path $entry
            switch ($collection) {
                'items' { ConvertTo-ZabbixSnmpCandidate $definition $entry $Template $false }
                'item_prototypes' { ConvertTo-ZabbixSnmpCandidate $definition $entry $Template $true }
                { $_ -in 'triggers', 'trigger_prototypes' } {
                    ConvertTo-ZabbixActiveCandidate $definition $entry $Template $Context $Rule $ItemContext
                }
                'discovery_rules' {
                    Set-ZabbixDefinitionState $definition 'Deferred' 'TABLE_DISCOVERY' 'Preserved for future SNMP Table filter/index/health translation; no live discovery was attempted.'
                }
                default { Set-ZabbixDefinitionState $definition 'Deferred' 'FEATURE_NOT_TRANSLATED' "Translation of $collection is not implemented." }
            }
            $disabled = $ParentDisabled -or [string]$entry['status'] -in @('DISABLED', '1')
            if ($disabled) {
                $definition.Candidate = $null
                Set-ZabbixDefinitionState $definition 'Disabled' 'SOURCE_DISABLED' 'Disabled in the source export or by its parent definition.'
            }
            elseif ($HasLinks -and $definition.Status -eq 'Ready') {
                $definition.Candidate = $null
                Set-ZabbixDefinitionState $definition 'NeedsInput' 'LINKED_TEMPLATES' 'Resolve linked templates before exporting ready collectors.'
            }
            $Definitions.Add($definition)
            $childRule = $Rule
            $childItem = $ItemContext
            if ($collection -eq 'discovery_rules') { $childRule = $entry; $childItem = $null }
            if ($collection -in @('items', 'item_prototypes')) { $childItem = $entry }
            Add-ZabbixDefinitions -Source $entry -Definitions $Definitions -Template $Template -Location "$path." -HasLinks $HasLinks -ParentDisabled $disabled -Depth ($Depth + 1) -Context $Context -Rule $childRule -ItemContext $childItem
        }
    }
}

# SIG # Begin signature block
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDhbgXwbjy4I+hz
# dUaMSkz/fpxIvIIJAvLGqkVvaoDEsqCCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0G
# CSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290
# IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28g
# UHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEe
# AEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGV
# oYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk
# 8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzh
# P06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41
# aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+
# ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/
# 2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9g
# Rvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhA
# QnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8B
# Af8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcD
# AzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyG
# Omh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5n
# Um9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYu
# cDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG
# 9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW
# 4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIh
# rCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYp
# mlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7Dc
# ML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yE
# Lg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRz
# NyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw
# 4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6
# E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6
# xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZt
# g0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggY+
# MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqGSIb3DQEBDAUAMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjYwMjA5MDAwMDAw
# WhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEUMBIGA1UECAwLQ29ubmVj
# dGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcwFQYDVQQDDA5KYXNvbiBB
# bGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPN6aN4B1yYW
# kI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyEtRYPxEmNJL3A38Bkg7mw
# zPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d67MlJLUAEufl18tOr3ST1
# DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2h4KdtRAnCqwM+/V7iBdb
# w+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAADLdjZr5ip8vIWbf857Yw1
# Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZBBL56l4YAlIVRsrOiE1k
# dHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDeyIq+Oztz1LvEdy8Rcd0J
# BY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN79CJ90UTZb2+I+tamj0d
# n+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+PhhamOxF2px9LObhBLLEMyRs
# CHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi2ttn6lLOPThXMiQaooRU
# q6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSMjDSRFDfHRCdGbZsL/keE
# LJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJMIIBhTAfBgNVHSMEGDAW
# gBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU6YF0o0D5AVhKHbVocr8G
# aSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcC
# ARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAw
# PqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVT
# aWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0
# cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIz
# Ni5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqG
# SIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvCwOA/RYQnFJD7R/bSQRu3
# wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03J5PrDTp1WPCWbXKX8Oz9
# vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9URrpiLPJ9rQjfHMb1BUd
# vaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6sX93wphwJNBJAstH9Ozs6
# LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+zzieGEI50fKnN77FfNKFO
# WKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcjGSHw4lTg1Wx+WMAMdl/7
# nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjsNrsk9ZlalBi5SHkIu+F6
# g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1nSX8OM++AXoyVGO+iTj7
# z+pl6XE9Gw/Td6WKKKswgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0G
# CSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0
# IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTla
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHT
# CphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPh
# of6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mA
# xAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBv
# MgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps
# 0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF
# 83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXi
# UOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOM
# CZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydP
# pOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrU
# G2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+
# sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0T
# AQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYD
# VR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNV
# HR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1s
# BwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WI
# GjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+
# IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8M
# yb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2
# th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjaj
# V/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2
# Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFze
# GxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG
# 7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+N
# Jpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckT
# etiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszW
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSb
# TGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP
# 0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3
# BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNF
# KZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbj
# brEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26Q
# ZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRs
# IolvykE1jive4PuESaT8zzVeFWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/S
# cpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5
# prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0
# ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwrocz
# k9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLa
# DXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEt
# rfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAd
# ZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAY
# yzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8
# pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v
# 5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeS
# WmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR
# 5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZ
# EbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjW
# agkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvd
# N8yWQPT9gzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCAobwAOYxRl5BZUNyDnaNfVvfGit8693ejZf8SavSY9vjANBgkqhkiG9w0BAQEF
# AASCAgDgrzAZnen7ZJPbrUu+7DxrBEpiVkBfxQOW2V4al9g36kTqSc7VBEB29bbM
# QgY2qiND1KmR0+5CHeSnaQi8mwrcwmbypuEphHdtyvcLndwF+p5SxMTs4XTfPVx3
# 7P6BzBovrVjpBV/Ta7iRG3eqEToF3TCKfnkCzcK3cm0j44Ku6AbHREbnu/LSXQbE
# QM0hDRvG9isHGSmkBuvh1zLoQ4TrN/a5SgtEE5h3FIWjpLC8RC0YRwwER2W7RJ64
# sa+Mq60NPrXDCsJWnbU0os/4bWYl53Gam2caXyL/ygXjJzHIIdNPrAKDjYv2mOJT
# BQOZRtCs9S8CgqfR6HaMLi6FN2SfnRf414kIFwAkVGE5TmOd61ceTRabE7UJ8dRn
# 56UjqYmDBNMFwuZWaR9QWjZKIGTHdqVxqfj3JmJELiW1uDSEeDELqj3gFrio5RyS
# H4Q2u5ukRwXV78d32bNzufrghMuIlaL1EJLMvkIBF1dmHmWUwtTJCeqXKIqSLQsh
# Le224Ou3n5aVQc78NWwBMHb15qsXQIpF5rqQ8zIMRq0m8VrIbHZKweaDFFa1wJMX
# DSPQQCFM94g62CzOY15DeudtDRK411X/CRgW0NgeY3BDJdrBBy6vwQmBEN3u/Ykr
# KgIQ8cm2P4g90IKK6PweYonrSlDEydQ+gCON2ZncON7rJgqVTaGCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mS
# GDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjEwMjEyMTA2MDlaMC8GCSqGSIb3DQEJBDEiBCCq7H28
# V9flOr1L2mL9xy7izl13YmXWMe4h477bTEd5FTANBgkqhkiG9w0BAQEFAASCAgAZ
# zuIFFBIt77wYlGKO/IDyXo6NJiW/2sYCT3sGQl7uc/c+r0fJi7DMkRSKhYIs3CwE
# PBvfwfuio9g/0SpAB1BD903DaabLpv7jgE4bJKf7QYKoL5WqnYF5xkjVApCsXiGW
# NIcDmxI7Hv+Bbxoxgi9D2GSCAbp6ef0sKx2fH2r3n/V5nqX5XtGbIev0zvwlQonL
# 1JeZc2i0f0l1jHBlmw688f6nFN2LgJd75VjQCCTsD/Jz30pHANgt67inTIhcr0hK
# zsStP89SZLSVWwnOO7KiZth6WH+3Bkds8hUA/cfVoW23cscoDNoceaVI1NOU45RL
# od9rChRO/1qv6KG19E71inNOPTiq8uEILBiieYbqyMJE/aJZ031D6e3/OhP+8avY
# Vbloh2taaEb3GWvtrIKvvzfVJ2fRkSOXUC+viLeQc+CGF1TVbz8ra3NvyHEzJyok
# dYUelBwv5SXiXlWKF8XbOXhB9Fib+8yg1GKezRwr3up2ENfk0ADOWls1E/0qXDF2
# VnKTDQ9exR+jZHb1fGFh0o5SmU7JAEvsTbH/7rylA8yLrN+cXfChULFuaVm09iYm
# BogDlb0lOuRSxgGDshiKPAnpLIqKp35UcxXLqAIx+9whwZfe2seklQBItQPWxqAH
# OS5MVajekg5pwF9my6vPTs0zpZlGb0h8IO4/1elU8w==
# SIG # End signature block
