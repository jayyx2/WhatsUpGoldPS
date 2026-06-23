function Export-DynamicDashboardHtml {
    <#
    .SYNOPSIS
        Generates an interactive HTML dashboard from any array of objects.
    .DESCRIPTION
        Takes any array of PSCustomObjects (or hashtables) and produces a self-contained
        HTML report with auto-generated summary cards, a sortable/searchable Bootstrap
        Table, row counter, pagination toggle, and multi-format export (CSV, XLSX, JSON,
        TXT, TSV, SQL, PNG, XLS).

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
# MIIr+wYJKoZIhvcNAQcCoIIr7DCCK+gCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC+0EzQtu7bHqTF
# W+GD4jQ4mDCrfep6zY0NHbHDWE9Tj6CCJQ0wggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# kPZPubdcMIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG9w0B
# AQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYg
# U0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1OVow
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIw
# MjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q6q5g
# VrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPnZ8ZN
# +vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSssp3qo
# me7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09ldQ/
# /nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98oksouT
# MYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+3qU8
# DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsnqcnp
# JeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQPdP5
# 1ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbSLZ49
# kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojTdS5P
# WPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoKRR7Y
# ufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAA
# MB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTvb1NK
# 6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8v
# b2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZT
# SEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk9iJP
# 2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tshgb4O
# 6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9mzskg
# iC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQBHMU
# BaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+YkDF
# kxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0cKsb+
# zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY7T/l
# wd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcbojBcxl
# RcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05oxYy2
# zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskKPIJg
# baP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjdNXOC
# IUjsarfNZzGCBkQwggZAAgEBMGgwVDELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1Nl
# Y3RpZ28gTGltaXRlZDErMCkGA1UEAxMiU2VjdGlnbyBQdWJsaWMgQ29kZSBTaWdu
# aW5nIENBIFIzNgIQB5zg5NEUf4XNOXPPdi036zANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCBZAp8DjxljTmal5tTiSYzFL1izTgQvc7E0M3BcNne4SDANBgkqhkiG9w0BAQEF
# AASCAgBPo8VJ4DsLIFalcSoVW/tsEOdS8LNYE2hlnTXkZiSZapzuRtJWU4Sk5bH4
# ieyWDmr8XG8ev+0ykf7swQ23UMwoXa6KXtQjHQyVEy4kejbsSbo2wmgVLGVmKy7h
# JAAeHNFTSjmetCV/C0vy57I2K/4RUlQ5Kh6734fFqVHM26oTIfCpYRE0DVY+h0ZA
# NXt3OqXMvq1bQu+ApUsmdpxwOeHIqPUAIgv+pmCEM6qYJ6d4Q7QSrzRfhaGFliWO
# ZFSezeKFt/SDfvtlf5v9pgALCwLGA0j5bDEd+KkeWR8gQiaTJmsIPTk+RxJtSxCe
# MrFrSWabYnT8hTBXkrlK3u3by8ztYsxyCLdu7nE6jlcUOmOLJ6TTHCgdX25I+HyG
# Bi9++B/BQHcWsjpYFkNHn+zGVcLF/8id+IwplLBLDAR6sFUjq+gnG5AXq9oJYwyh
# QAU3FG9fRpd0AuiTcq9iDdJEAO7jDNkBZpw4K8X6KS/Xrc61S5jjtPpnuEZQhxBU
# nA6GQ+mfgTE7GN+DZ/P761+d/NVllC5k4n5bLx7OzwYlyLrH/Hrlm7L6vORvdljd
# AgHcZNvWqDTGU1q/6CEZJJjUqU4n8OXnmuMqxdDZPrzfIDn6HKgi9GteGfMUMdUh
# 2ZIDepkw8Itf7MlsjnHokvpcN+Q6TbgNfu3u4yi86VIDf8J9s6GCAyYwggMiBgkq
# hkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeV
# dGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwG
# CSqGSIb3DQEJBTEPFw0yNjA2MjMxMTM1MTJaMC8GCSqGSIb3DQEJBDEiBCAMTa4s
# omE5uFC3RhOmCKGvWmtN5CrLk1ORrnnf0yvfeDANBgkqhkiG9w0BAQEFAASCAgAy
# sVOmTrGnaxpc0PJiaP4pHfgfiyPw7L/CA4fPBuZODSpHuWcvb3DLf85116XyOAmC
# R62R2nIRPgKi5injLfxJ7ZK8P11piWHddHHtl2t1kXDByaZCc3yJzP4TFDfG4tYS
# 4G+mjF7jR08jLUIIULmL69NyaTRjgf/Ba8Hq6Qsh7qmUTis/FvhScCwupv257NSQ
# N1hZQA/xptN7m1v3WmMfn6aCgzSeHsnJxdJ33RAEFFGMDrKHTb3Ul93eD+6OL0JU
# lRId8UDwFiFTKveaO4qM7V/+UBsxKbxVqoT0ghRg6A9jd8UCLtMVDPeDl0b/M09+
# urUUW5NQ0+vniIFmj0J8MRzIGOXkIPAMspUu+c/DKlNF4bG6wyesyf1CAAgSTMUd
# 3AAmtIxIr7IqnbKUr3QOJwaOqRyFGbPc0avQtzdmmCRDlJVSUT1PMO2wzGzn5Mpa
# W79bw5+xD7gBJjJyU1y3WsT42eJ5q6pgoz+oNhIUO7wVQMkj72pVZbzUpP6glx+W
# rTFMX02iw7xzbG7aAM9WRA23PXuqnUMNi8Lfo8QtbF8FO+Vc2Pgg6Zd6RAspwHwo
# jMKFE5ZD9KAhD8xG46ExSym9j0W4vrVai4qlSVTKFhR1KS7SXO7uRD8OYZ+5OvbS
# 5ca6GmtODB30AsFnO3nrfxql9wKFFZKzh2Zusr296w==
# SIG # End signature block
