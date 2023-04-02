function ConvertTo-BootstrapTable {
    param (
        [Parameter(Mandatory=$true)]
        [string] $JsonFilePath
    )

    $jsonData = Get-Content -Path $JsonFilePath | ConvertFrom-Json
    $firstObject = $jsonData[0]

    $columns = @()
    $firstObject.PSObject.Properties | ForEach-Object {
        $column = @{
            field = $_.Name
            title = $_.Name
        }
        if ($_.Name -eq 'downActiveMonitors') {
            $column.formatter = 'formatDownActiveMonitors'
        }
        if ($_.Name -eq 'id') {
            $column.formatter = 'formatId'
        }
        $columns += $column
    }

    $columnsJson = $columns | ConvertTo-Json -Depth 5 -Compress
    $dataJson = $jsonData | ConvertTo-Json -Depth 5 -Compress

    return @"
        columns: $columnsJson,
        data: $dataJson
"@
}
