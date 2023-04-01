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
        $columns += $column
    }

    $columnsJson = $columns | ConvertTo-Json -Compress
    $dataJson = $jsonData | ConvertTo-Json -Compress

    return @"
        columns: $columnsJson,
        data: $dataJson
"@
}
