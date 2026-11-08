function Export-DynamicDashboardHtml {
    <#
    .SYNOPSIS
        Generates an interactive HTML dashboard from any array of objects.
    .DESCRIPTION
        Takes any array of PSCustomObjects (or hashtables) and produces a self-contained
        HTML report with auto-generated summary cards, a sortable/searchable Bootstrap
        Table, row counter, pagination toggle, and multi-format export (CSV, XLSX, JSON,
        TXT, TSV, SQL, PNG, XLS).
        JSON embedded in the page escapes less-than characters so inventory text
        cannot close the script element.

        Summary cards are auto-detected from the data:
        - A "Total" card is always generated first.
        - If a -CardField is specified, unique values of that field become clickable
          filter cards.
        - If -CardField is not specified, the function looks for common status-like
          fields (Status, State, PowerState, ProvisioningState, Health, Result) and
          uses the first one found.
        - If no status-like field is found, up to 5 low-cardinality string fields
          (fewer than 10 unique values) are auto-detected and used as card groups.

        Column titles are auto-humanised from PascalCase (e.g. "IPAddress" becomes
        "IP Address"). A -StatusField can mark a column for automatic colour-coded
        formatting (green/red/orange dots based on common status keywords).
    .PARAMETER Data
        Array of objects to render. Accepts pipeline input.
    .PARAMETER OutputPath
        File path for the output HTML file. If omitted, defaults to
        $env:TEMP\WhatsUpGoldPS-Report-<datetime>.html.
    .PARAMETER ReportTitle
        Title shown in the report header and browser tab. Defaults to "Dashboard".
    .PARAMETER CardField
        One or more property names to group summary cards by. Each field gets
        its own labelled row of cards. Accepts an array, e.g. -CardField 'role','bestState'.
        If omitted, auto-detection picks common status-like fields.
    .PARAMETER StatusField
        Property name to apply automatic status colour formatting to (green dot
        for running/active/up, red dot for stopped/failed/down, etc.). If omitted,
        auto-detection looks for common status field names.
    .PARAMETER ExportPrefix
        Filename prefix for exported files (e.g. "my_report" produces
        "my_report.csv"). Defaults to "dashboard_export".
    .PARAMETER ThresholdField
        One or more hashtables defining numeric threshold colouring for columns.
        Each hashtable must contain: Field (property name), Warning (number),
        Critical (number). Optionally add Invert=$true when lower values are
        worse (e.g. free disk space).

        Normal (default):  >= Critical = red, >= Warning = orange, else green.
        Inverted:          <= Critical = red, <= Warning = orange, else green.

        Example:
          -ThresholdField @{Field='cpuUtil'; Warning=80; Critical=90},
                          @{Field='diskFreePercent'; Warning=20; Critical=10; Invert=$true}
    .PARAMETER TemplatePath
        Path to a custom HTML template. Defaults to Dynamic-Dashboard-Template.html
        in the same directory as this script.
    .PARAMETER Offline
        When specified, rewrites CDN URLs to local file:/// paths pointing to the
        dependency folder (helpers\reports\dependency\). Use this for environments
        without internet access. The dependency files must be pre-downloaded.
    .EXAMPLE
        Get-Process | Select-Object Name, Id, CPU, WorkingSet |
            Export-DynamicDashboardHtml -OutputPath "$env:TEMP\procs.html" -ReportTitle "Processes"
        Start-Process "$env:TEMP\procs.html"

        Generates a process dashboard and opens it in the default browser.
    .EXAMPLE
        $data = Get-Content .\servers.json | ConvertFrom-Json
        Export-DynamicDashboardHtml -Data $data -OutputPath "C:\Reports\servers.html" `
            -ReportTitle "Server Inventory" -CardField "Status","Role" -StatusField "Status"

        Generates a server inventory dashboard with two card rows: one grouped by Status, one by Role.
    .EXAMPLE
        Import-Csv .\assets.csv |
            Export-DynamicDashboardHtml -OutputPath "$env:TEMP\assets.html" `
                -ReportTitle "Asset Report" -CardField "Location" -ExportPrefix "assets"

        Generates a dashboard from CSV data, grouped by Location.
    .OUTPUTS
        System.String  The full path of the generated HTML file.
    .NOTES
        Author  : jason@wug.ninja
        Version : 1.0.0
        Requires: PowerShell 5.1+
    .LINK
        https://github.com/jayyx2/WhatsUpGoldPS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Data,

        [string]$OutputPath,

        [string]$ReportTitle = 'Dashboard',

        [string[]]$CardField,

        [string]$StatusField,

        [string]$ExportPrefix = 'dashboard_export',

        [hashtable[]]$ThresholdField,

        [string]$TemplatePath,

        [string]$IndexUrl,

        [switch]$Offline
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Data) {
            $collected.Add($item)
        }
    }

    end {
        # Disable strict mode inside this function — the dynamic object
        # manipulation (property enumeration, cardinality checks, JSON
        # building) uses .Count on variables that may be single objects
        # rather than arrays. Callers with Set-StrictMode -Version Latest
        # would break without this.
        Set-StrictMode -Off

        if ($collected.Count -eq 0) {
            throw "No data provided. Supply at least one object."
        }

        # --- Resolve OutputPath ---
        if (-not $OutputPath) {
            $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $OutputPath = Join-Path $env:TEMP "WhatsUpGoldPS-Report-$timestamp.html"
        }

        # --- Resolve template ---
        if (-not $TemplatePath) {
            $TemplatePath = Join-Path $PSScriptRoot 'Dynamic-Dashboard-Template.html'
        }
        if (-not (Test-Path $TemplatePath)) {
            throw "HTML template not found at $TemplatePath"
        }

        $allData = @($collected)

        # --- Flatten nested objects/arrays to readable strings ---
        $flatData = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $allData) {
            $flat = [ordered]@{}
            foreach ($prop in $row.PSObject.Properties) {
                $val = $prop.Value
                if ($null -eq $val) {
                    $flat[$prop.Name] = $null
                }
                elseif ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                    # Array or collection
                    $items = @($val)
                    if ($items.Count -eq 0) {
                        $flat[$prop.Name] = ''
                    }
                    elseif ($items[0] -is [string] -or $items[0] -is [ValueType]) {
                        # Array of simple values — join with comma
                        $flat[$prop.Name] = ($items | ForEach-Object { "$_" }) -join ', '
                    }
                    else {
                        # Array of objects — pick a display name or flatten each
                        $parts = @()
                        foreach ($obj in $items) {
                            $props = @($obj.PSObject.Properties)
                            # Try common display properties first
                            $displayVal = $null
                            foreach ($dn in @('Name','DisplayName','name','displayName','Title','title','Id','id','Description')) {
                                $found = $props | Where-Object { $_.Name -eq $dn } | Select-Object -First 1
                                if ($found -and $found.Value) {
                                    $displayVal = "$($found.Value)"
                                    break
                                }
                            }
                            if ($displayVal) {
                                $parts += $displayVal
                            }
                            else {
                                # Fallback: key=value pairs for up to 3 properties
                                $kvPairs = @()
                                foreach ($p in ($props | Select-Object -First 3)) {
                                    $pv = $p.Value
                                    if ($pv -is [System.Collections.IEnumerable] -and $pv -isnot [string]) {
                                        $pv = ($pv | ForEach-Object { "$_" }) -join '; '
                                    }
                                    $kvPairs += "$($p.Name)=$pv"
                                }
                                $parts += ($kvPairs -join ', ')
                            }
                        }
                        $flat[$prop.Name] = $parts -join ' | '
                    }
                }
                elseif ($val.PSObject.Properties.Count -gt 0 -and $val -isnot [string] -and $val -isnot [ValueType] -and $val -isnot [datetime]) {
                    # Single nested object — flatten to key=value
                    $kvPairs = @()
                    foreach ($p in ($val.PSObject.Properties | Select-Object -First 5)) {
                        $pv = $p.Value
                        if ($pv -is [System.Collections.IEnumerable] -and $pv -isnot [string]) {
                            $pv = ($pv | ForEach-Object { "$_" }) -join '; '
                        }
                        $kvPairs += "$($p.Name)=$pv"
                    }
                    $flat[$prop.Name] = $kvPairs -join ', '
                }
                else {
                    $flat[$prop.Name] = $val
                }
            }
            $flatData.Add([PSCustomObject]$flat)
        }
        $allData = @($flatData)
        $firstObj = $allData[0]

        # --- Helper: resolve a field name to the actual property name (exact case) ---
        # PowerShell is case-insensitive but JavaScript is not. We must use the
        # real property name so JSON keys match in the browser.
        $propNames = @($firstObj.PSObject.Properties.Name)
        function Resolve-FieldName ([string]$Name) {
            foreach ($p in $propNames) {
                if ($p -ieq $Name) { return $p }
            }
            return $null
        }

        # --- Auto-detect StatusField ---
        $knownStatusFields = @('Status','State','PowerState','ProvisioningState','Health','Result','Availability','bestState')
        if ($StatusField) {
            $resolved = Resolve-FieldName $StatusField
            if ($resolved) { $StatusField = $resolved } else { Write-Warning "StatusField '$StatusField' not found in data. Ignoring."; $StatusField = $null }
        }
        else {
            foreach ($sf in $knownStatusFields) {
                $resolved = Resolve-FieldName $sf
                if ($resolved) {
                    $StatusField = $resolved
                    Write-Verbose "Auto-detected status field: $StatusField"
                    break
                }
            }
        }

        # --- Resolve CardField(s) ---
        $resolvedCardFields = @()
        if ($CardField -and $CardField.Count -gt 0) {
            foreach ($cf in $CardField) {
                $resolved = Resolve-FieldName $cf
                if ($resolved) { $resolvedCardFields += $resolved }
                else { Write-Warning "CardField '$cf' not found in data. Ignoring." }
            }
        }
        if ($resolvedCardFields.Count -eq 0) {
            # Auto-detect: try known status fields first
            foreach ($sf in $knownStatusFields) {
                $resolved = Resolve-FieldName $sf
                if ($resolved) {
                    $resolvedCardFields += $resolved
                    Write-Verbose "Auto-detected card field: $resolved"
                    break
                }
            }
        }
        if ($resolvedCardFields.Count -eq 0) {
            # Fallback: first low-cardinality string column
            foreach ($prop in $firstObj.PSObject.Properties) {
                $sample = @($allData | ForEach-Object { $_.$($prop.Name) } | Where-Object { $_ -ne $null -and $_ -ne '' } | Select-Object -Unique)
                if ($sample.Count -ge 2 -and $sample.Count -le 15) {
                    $avgLen = ($sample | ForEach-Object { "$_".Length } | Measure-Object -Average).Average
                    if ($avgLen -le 30) {
                        $resolvedCardFields += $prop.Name
                        Write-Verbose "Auto-detected card field (low-cardinality): $($prop.Name)"
                        break
                    }
                }
            }
        }

        # --- Build card groups (one group per CardField) ---
        $cardGroups = @()
        foreach ($field in $resolvedCardFields) {
            # Humanise the field name for the group label
            $label = $field -creplace '([a-z])([A-Z])', '$1 $2'
            $label = ($label -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2').Trim()
            $label = $label.Substring(0,1).ToUpper() + $label.Substring(1)

            # Count occurrences of each unique value
            $valueCounts = @{}
            foreach ($val in @($allData | ForEach-Object { $_.$field } | Where-Object { $_ -ne $null -and $_ -ne '' })) {
                $key = "$val"
                if (-not $valueCounts.ContainsKey($key)) {
                    $valueCounts[$key] = 0
                }
                $valueCounts[$key]++
            }

            # Separate frequent and rare values; only collapse into "others" when >6 distinct values
            $allVals = @($valueCounts.Keys | Sort-Object)
            if ($allVals.Count -gt 6) {
                $frequentVals = @($valueCounts.Keys | Where-Object { $valueCounts[$_] -gt 1 } | Sort-Object)
                $rareVals = @($valueCounts.Keys | Where-Object { $valueCounts[$_] -eq 1 } | Sort-Object)
            } else {
                $frequentVals = $allVals
                $rareVals = @()
            }

            $cards = @()
            $cards += @{ label = 'Total'; filterField = '__total__' }
            
            # Add cards only for values that appear >1 time
            foreach ($val in $frequentVals) {
                $cards += @{
                    label        = "$val"
                    filterField  = $field
                    filterValues = @("$val".ToLower())
                }
            }

            # Add "others" card if there are rare values
            if ($rareVals.Count -gt 0) {
                $cards += @{
                    label        = "others"
                    filterField  = $field
                    filterValues = @($rareVals | ForEach-Object { $_.ToLower() })
                }
            }

            $cardGroups += @{ groupLabel = $label; cards = $cards }
        }
        if ($cardGroups.Count -eq 0) {
            # No card fields at all — just show a Total card
            $cardGroups += @{ groupLabel = 'Summary'; cards = @(@{ label = 'Total'; filterField = '__total__' }) }
        }

        $cardGroupsJson = $cardGroups | ConvertTo-Json -Depth 5 -Compress
        if ($cardGroups.Count -eq 1) { $cardGroupsJson = "[$cardGroupsJson]" }

        # --- Resolve ThresholdField definitions ---
        $thresholdDefs = @()
        if ($ThresholdField) {
            foreach ($tf in $ThresholdField) {
                if (-not $tf.Field) { Write-Warning 'ThresholdField entry missing Field key. Skipping.'; continue }
                if ($null -eq $tf.Warning -or $null -eq $tf.Critical) { Write-Warning "ThresholdField '$($tf.Field)' missing Warning or Critical. Skipping."; continue }
                $resolved = Resolve-FieldName $tf.Field
                if (-not $resolved) { Write-Warning "ThresholdField '$($tf.Field)' not found in data. Skipping."; continue }
                $thresholdDefs += @{
                    field    = $resolved
                    warning  = [double]$tf.Warning
                    critical = [double]$tf.Critical
                    invert   = [bool]$tf.Invert
                }
                Write-Verbose "Threshold: $resolved warning=$($tf.Warning) critical=$($tf.Critical) invert=$($tf.Invert)"
            }
        }
        $thresholdDefsJson = $thresholdDefs | ConvertTo-Json -Depth 5 -Compress
        if ($thresholdDefs.Count -le 1) { $thresholdDefsJson = "[$thresholdDefsJson]" }

        # --- Build columns ---
        $columns = @()
        foreach ($prop in $firstObj.PSObject.Properties) {
            # Humanise PascalCase/camelCase: hostName→Host Name, IPAddress→IP Address
            $title = $prop.Name -creplace '([a-z])([A-Z])', '$1 $2'
            $title = ($title -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2').Trim()
            $title = $title.Substring(0,1).ToUpper() + $title.Substring(1)

            $col = @{
                field      = $prop.Name
                title      = $title
                sortable   = $true
                searchable = $true
            }

            if ($StatusField -and $prop.Name -eq $StatusField) {
                $col.formatter = 'formatStatusAuto'
            }

            # Check if this column has a threshold definition
            $matchingThreshold = $thresholdDefs | Where-Object { $_.field -eq $prop.Name } | Select-Object -First 1
            if ($matchingThreshold) {
                $col.formatter = 'formatThreshold'
            }

            $columns += $col
        }

        $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
        $dataJson    = $allData  | ConvertTo-Json -Depth 5 -Compress

        # Handle single-item arrays (ConvertTo-Json unwraps single-element arrays)
        if ($columns.Count -eq 1) {
            $columnsJson = "[$columnsJson]"
        }
        if ($allData.Count -eq 1) {
            $dataJson = "[$dataJson]"
        }

        # Inventory descriptions must not terminate the template's script element.
        $columnsJson = $columnsJson.Replace('<', '\u003c')
        $dataJson = $dataJson.Replace('<', '\u003c')
        $cardGroupsJson = $cardGroupsJson.Replace('<', '\u003c')
        $thresholdDefsJson = $thresholdDefsJson.Replace('<', '\u003c')

        $tableConfig = @"
        columns: $columnsJson,
        data: $dataJson
"@

        # --- Render template ---
        # Use [string].Replace() instead of -replace to avoid regex interpretation
        # of $ characters in JSON data or user-supplied strings.
        $html = Get-Content -Path $TemplatePath -Raw
        $html = $html.Replace('replaceThisHere',              $tableConfig)
        $html = $html.Replace('replaceSummaryCardsHere',      $cardGroupsJson)
        $html = $html.Replace('replaceThresholdDefsHere',     $thresholdDefsJson)
        $html = $html.Replace('replaceExportPrefixHere',      $ExportPrefix)
        $html = $html.Replace('ReplaceYourReportNameHere',    $ReportTitle)
        $html = $html.Replace('ReplaceUpdateTimeHere',        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

        # --- Back navigation button (only when IndexUrl is provided) ---
        if ($IndexUrl) {
            $backNav = @"
        <div class="mb-3">
            <a href="$IndexUrl" class="btn btn-sm btn-outline-secondary" title="Back to dashboard index">
                <i class="bi bi-arrow-left"></i> back to index
            </a>
        </div>
"@
        } else {
            $backNav = ''
        }
        $html = $html.Replace('replaceBackNavHere', $backNav)

        # --- Resolve local dependencies (offline mode) ---
        if ($Offline) {
            $depFolder = Join-Path $PSScriptRoot 'dependency'
            if (Test-Path $depFolder) {
                $depUri = ([System.Uri](Resolve-Path $depFolder).Path).AbsoluteUri
                $cdnMap = @{
                    'https://cdn.jsdelivr.net/npm/bootstrap/dist/css/bootstrap.min.css'       = "$depUri/bootstrap.min.css"
                    'https://cdn.jsdelivr.net/npm/bootstrap-table/dist/bootstrap-table.min.css' = "$depUri/bootstrap-table.min.css"
                    'https://cdn.jsdelivr.net/npm/bootstrap-icons/font/bootstrap-icons.min.css' = "$depUri/bootstrap-icons.min.css"
                    'https://cdn.jsdelivr.net/npm/jquery/dist/jquery.min.js'                  = "$depUri/jquery.min.js"
                    'https://cdn.jsdelivr.net/npm/@popperjs/core/dist/umd/popper.min.js'      = "$depUri/popper.min.js"
                    'https://cdn.jsdelivr.net/npm/bootstrap/dist/js/bootstrap.min.js'         = "$depUri/bootstrap.min.js"
                    'https://cdn.jsdelivr.net/npm/bootstrap-table/dist/bootstrap-table.min.js' = "$depUri/bootstrap-table.min.js"
                    'https://cdn.jsdelivr.net/npm/file-saver/dist/FileSaver.min.js'           = "$depUri/FileSaver.min.js"
                    'https://cdn.jsdelivr.net/npm/xlsx/dist/xlsx.full.min.js'                 = "$depUri/xlsx.full.min.js"
                    'https://cdn.jsdelivr.net/npm/html2canvas/dist/html2canvas.min.js'        = "$depUri/html2canvas.min.js"
                }
                foreach ($cdn in $cdnMap.GetEnumerator()) {
                    $html = $html.Replace($cdn.Key, $cdn.Value)
                }

                # Local file:/// dependencies can fail in Chromium when crossorigin is present.
                # Remove it in offline mode to keep jquery/bootstrap loading deterministic.
                $html = [regex]::Replace($html, '\s+crossorigin="anonymous"', '')
                Write-Verbose "Using local dependencies from $depFolder"
            }
            else {
                Write-Warning "Offline mode requested but dependency folder not found at $depFolder. Using CDN URLs."
            }
        }

        Set-Content -Path $OutputPath -Value $html -Encoding UTF8
        Write-Verbose "Dashboard written to $OutputPath"
        return $OutputPath
    }
}

# SIG # Begin signature block
# MIImiAYJKoZIhvcNAQcCoIImeTCCJnUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC7JPxzeVwLRCD6
# EjFeRCq+3xdwSt9QvhEHTBJuMpunBaCCH5owggWNMIIEdaADAgECAhAOmxiO+dAt
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDp
# e4voR6TTuYXtrpKtnqaP/Nj3lfMa8ksDIF6l3dtffjANBgkqhkiG9w0BAQEFAASC
# AgCpo8bxjJCFB7eNPzrpGtxLK4et3Zk9xrdFXW3ipm7Kszvsp4QCa7ml1pv/THlx
# k3fnrppQVDM12t0yjFszQIJwPbF+smDsrkylvj8Hh2NexbT58ZCYUV20bc5uiCdb
# kW70q2ylCnsKB7VubLdK1G4w6/qhoUhFCPsY8LuysG74J3XKKIiVQ+nE60zj9Bm5
# 3fLy4NmjDc4jA8q3jXcfRP3rk1RqwEz0OwckV3TT26q3qOdJEWUWdQqKO522yTAW
# krOV2kYi5Soqd5uQ4jnmlB3uz3lN45iPSZmYkZ2BaUTbocvVN+8I0Rsf/ZCm9Ggv
# LauKAJh6HDtM1HBM38LbvLBvyGNsi6GM73NPD+wrnoq5y8bMxM8DlI+mlfnNCVB2
# VeMSNf1wFx7W+XRL70ce0vKxqvctyetcnZjyLBHYRhP2wYzzMK1F2pGV7iDfT8zt
# klsQbfgjsUeCh3f2w/99JwZ/UKbFDoVtyBweef0GrROhxDgl4orkD4TDZf+ckzw9
# PwwjwtgRhboqthlFtC2AA5ZruMeJ8TAqC9qt1/Rp30yMoed7h4tdYeLGppcIjcsh
# 1B20qY6+QL+Bv1Ur7UGO2HOnR3ms4r3NG565LQwAOHTiupyFxnFjBLbMGkOW6yas
# b3LvEa7U8C6ER6DKc9W8CQoxfccHip00JrxCQ2EbGzBmbqGCAyYwggMiBgkqhkiG
# 9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3Rh
# bXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MPj/mSGDUw
# DQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqG
# SIb3DQEJBTEPFw0yNjExMDgxNTI4MzRaMC8GCSqGSIb3DQEJBDEiBCBhdJZhwbL4
# AEnUGtWq3VQEH4NwgshXWzPGuRWtzuiGMjANBgkqhkiG9w0BAQEFAASCAgCfBAkP
# Mh/udr/pmUT9xn/DPzMY22udFKMOEsEvzpR03lN16WjMp0lItsrk9ohDO7FU+eRc
# wgifn2O4Wdq59eGkUiDYuJBBRYYTICgKSCY77E0GvfnCr+C2WiLXuzq2rpvIfD2F
# fw3eK5gLd6TASqIcJCS1/jfdKRmAIpseRtj3eQw3hYnTK8Wx7JJ5YWGSny1Fi1Pr
# gzgUfONVP1CQ/MTIQQcroCqSUofF25P34Gq968+0KukQMSy/cGQjiJ9gRc3XQxtk
# TbZOHUo7wA3rNppuNaoj/tyPlirl9IXM4vP8lz3oLUrXQuILXMsN81vRxJdX0Dvr
# Kb05U0gN/1Qk7oKvKii6kO1fewQVwfJ8OdQebsuq2mOfke7qEWMxgA5B/FJpURVH
# j8cSYFPEGD/F5TXqwDmFRNsRucHR86L8nJLDV8pOsGCdTkxKh4/NzQVdcMXNG1NT
# zDvkyrCS3xaZdIMmTrCzxlrF/n04cJaA6UKUpYA/M9LWzUJorhpUZ1LUmt+tGite
# 3IYWp5dspkbUk2NTj2q8em2ClHjfX5Jv547u4vghOR/9hKnEZlbylwXq5GFmdZCG
# Up/tYWPRVGIZcTUfCuO99GnPy36REkGMFmgYErfR2oNfaZ5iwX4ZEoqxMYrGz9/b
# hGMHNT5uxzPOztHdyVYsBxtg8PUH2ayGPvy/VQ==
# SIG # End signature block
