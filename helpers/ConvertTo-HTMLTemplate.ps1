function Convert-HTMLTemplate {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TemplateFilePath,

        [Parameter(Mandatory = $true)]
        [string] $JsonFilePath,

        [Parameter(Mandatory = $true)]
        [string] $OutputFilePath,

        [Parameter(Mandatory = $true)]
        [string] $Placeholder,

        [string] $ReportName = 'Custom Report',
        [string] $UpdateTime
    )

    $JSONtoReplace = ConvertTo-BootstrapTable -JsonFilePath $JsonFilePath
    $replacement = "$JSONtoReplace"

    $htmlTemplate = Get-Content -Path $TemplateFilePath -Raw
    $htmlTemplate = $htmlTemplate -replace $Placeholder, $replacement

    $htmlTemplate = $htmlTemplate -replace 'ReplaceYourReportNameHere', $ReportName

    if (-not $UpdateTime) {
        $UpdateTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    $htmlTemplate = $htmlTemplate -replace 'ReplaceUpdateTimeHere', $UpdateTime

    Set-Content -Path $OutputFilePath -Value $htmlTemplate
}