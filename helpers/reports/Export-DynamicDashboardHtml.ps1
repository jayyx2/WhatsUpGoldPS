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

            $uniqueVals = @($allData | ForEach-Object { $_.$field } | Where-Object { $_ -ne $null -and $_ -ne '' } | Sort-Object | Select-Object -Unique)
            $cards = @()
            $cards += @{ label = 'Total'; filterField = '__total__' }
            foreach ($val in $uniqueVals) {
                $cards += @{
                    label        = "$val"
                    filterField  = $field
                    filterValues = @("$val".ToLower())
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
# MIIVlwYJKoZIhvcNAQcCoIIViDCCFYQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAQ1WVQrFj856aK
# mdhQ7N1kXBkVDcD4gEcKlqcLgt/qWKCCEdMwggVvMIIEV6ADAgECAhBI/JO0YFWU
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
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggYaMIIEAqADAgECAhBiHW0M
# UgGeO5B5FSCJIRwKMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENv
# ZGUgU2lnbmluZyBSb290IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5
# NTlaMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzAp
# BgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjI
# ztNsfvxYB5UXeWUzCxEeAEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NV
# DgFigOMYzB2OKhdqfWGVoYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/3
# 6F09fy1tsB8je/RV0mIk8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05Zw
# mRmTnAO5/arnY83jeNzhP06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm
# +qxp4VqpB3MV/h53yl41aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUe
# dyz8rNyfQJy/aOs5b4s+ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz4
# 4MPZ1f9+YEQIQty/NQd/2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBM
# dlyh2n5HirY4jKnFH/9gRvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQY
# MBaAFDLrkpr/NZZILyhAQnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritU
# pimqF6TNDDAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNV
# HSUEDDAKBggrBgEFBQcDAzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsG
# A1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY0NvZGVTaWduaW5nUm9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsG
# AQUFBzAChjpodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2Rl
# U2lnbmluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0
# aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURh
# w1aVcdGRP4Wh60BAscjW4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0Zd
# OaWTsyNyBBsMLHqafvIhrCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajj
# cw5+w/KeFvPYfLF/ldYpmlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNc
# WbWDRF/3sBp6fWXhz7DcML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalO
# hOfCipnx8CaLZeVme5yELg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJs
# zkyeiaerlphwoKx1uHRzNyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z7
# 6mKnzAfZxCl/3dq3dUNw4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5J
# KdGvspbOrTfOXyXvmPL6E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHH
# j95Ejza63zdrEcxWLDX6xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2
# Bev6SivBBOHY+uqiirZtg0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/
# L9Uo2bC5a4CH2RwwggY+MIIEpqADAgECAhAHnODk0RR/hc05c892LTfrMA0GCSqG
# SIb3DQEBDAUAMFQxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYw
# HhcNMjYwMjA5MDAwMDAwWhcNMjkwNDIxMjM1OTU5WjBVMQswCQYDVQQGEwJVUzEU
# MBIGA1UECAwLQ29ubmVjdGljdXQxFzAVBgNVBAoMDkphc29uIEFsYmVyaW5vMRcw
# FQYDVQQDDA5KYXNvbiBBbGJlcmlubzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAPN6aN4B1yYWkI5b5TBj3I0VV/peETrHb6EY4BHGxt8Ap+eT+WpEpJyE
# tRYPxEmNJL3A38Bkg7mwzPE3/1NK570ZBCuBjSAn4mSDIgIuXZnvyBO9W1OQs5d6
# 7MlJLUAEufl18tOr3ST1DeO9gSjQSAE5Nql0QDxPnm93OZBon+Fz3CmE+z3MwAe2
# h4KdtRAnCqwM+/V7iBdbw+JOxolpx+7RVjGyProTENIG3pe/hKvPb501lf8uBAAD
# LdjZr5ip8vIWbf857Yw1Bu10nVI7HW3eE8Cl5//d1ribHlzTzQLfttW+k+DaFsKZ
# BBL56l4YAlIVRsrOiE1kdHYYx6IGrEA809R7+TZA9DzGqyFiv9qmJAbL4fDwetDe
# yIq+Oztz1LvEdy8Rcd0JBY+J4S0eDEFIA3X0N8VcLeAwabKb9AjulKXwUeqCJLvN
# 79CJ90UTZb2+I+tamj0dn+IKMEsJ4v4Ggx72sxFr9+6XziodtTg5Luf2xd6+Phha
# mOxF2px9LObhBLLEMyRsCHZIzVZOFKu9BpHQH7ufGB+Sa80Tli0/6LEyn9+bMYWi
# 2ttn6lLOPThXMiQaooRUq6q2u3+F4SaPlxVFLI7OJVMhar6nW6joBvELTJPmANSM
# jDSRFDfHRCdGbZsL/keELJNy+jZctF6VvxQEjFM8/bazu6qYhrA7AgMBAAGjggGJ
# MIIBhTAfBgNVHSMEGDAWgBQPKssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQU
# 6YF0o0D5AVhKHbVocr8GaSIBibAwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQC
# MAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIB
# AwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EM
# AQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2Vj
# dGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBE
# BggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# Q29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNl
# Y3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQAEIsm4xnOd/tZMVrKwi3doAXvC
# wOA/RYQnFJD7R/bSQRu3wXEK4o9SIefye18B/q4fhBkhNAJuEvTQAGfqbbpxow03
# J5PrDTp1WPCWbXKX8Oz9vGWJFyJxRGftkdzZ57JE00synEMS8XCwLO9P32MyR9Z9
# URrpiLPJ9rQjfHMb1BUdvaNayomm7aWLAnD+X7jm6o8sNT5An1cwEAob7obWDM6s
# X93wphwJNBJAstH9Ozs6LwISOX6sKS7CKm9N3Kp8hOUue0ZHAtZdFl6o5u12wy+z
# zieGEI50fKnN77FfNKFOWKlS6OJwlArcbFegB5K89LcE5iNSmaM3VMB2ADV1FEcj
# GSHw4lTg1Wx+WMAMdl/7nbvfFxJ9uu5tNiT54B0s+lZO/HztwXYQUczdsFon3pjs
# Nrsk9ZlalBi5SHkIu+F6g7tWiEv3rtVApmJRnLkUr2Xq2a4nbslUCt4jKs5UX4V1
# nSX8OM++AXoyVGO+iTj7z+pl6XE9Gw/Td6WKKKsxggMaMIIDFgIBATBoMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCEAec4OTRFH+FzTlzz3Yt
# N+swDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgBNfDxsa9DKzn+Uu5BFezjjE2ALSqBz89
# JDK4LK2HFZ8wDQYJKoZIhvcNAQEBBQAEggIAlggEKXT8t0YtCriDTlNGlOMYQEdf
# Nt/X6pgDErRI8ph+TzkLoWfLNgyxRzpcgzybqdjM8vgQy2qDgomO04/fsW0tfBDR
# 41pjQPRDOJ4sP1ktC+ryVcCc9Qab9wkhyTR5zPiqWdbMH2Rlg6ky0ldmw7OGS/9Y
# p54WJflGgbwZXY6who3QryAYEn3vEoCWgJ/Pio+MNzsBBwVvoWA0QsfI0AKZQ9SQ
# ArHR65ZxiiJZErIQ8mgnwbe5HUsOYdrOsWuCef4OmisFTLKE+Hk1O5QkJnpS4ZLa
# J5hq1G0XWaKsyigKdHwFtn8iVs80rA/YrqjTH5uDaLG4Z+yuv4xsKt11KJqMgltE
# k9g1ypRYweShyxAa8TpljpC20eLLOiN1We4/nDlLm5BISjU2nkoYeotFlj4dPycd
# yN0pXQngWF7c8u0UQ2O/utpTymgwKtBjCQALDyeJoaRtKEu/EfB6xM7gliEVO6Cp
# 1H7FM4hJvIeWff/HLeMAA5KQqfPruU38AlbVHKCksOLwp9eGwuvmD/cPvYnHoyYS
# 6/UrNSsnKlJxv2lybzQ0DgUy9dLbnlOueN2UpVt4mCrAO2kRucGDmEnlpVDlk+t2
# fYgKqQ8FOLBpRd9iXE6M7DoJVRjptFNa3vWOtfzYMJMMD4vFS2ABx3HlxLLdGM1z
# sc3ZYbiTbirxGiY=
# SIG # End signature block
