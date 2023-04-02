if(!$Credential){
    $Credential = Get-Credential
}
$ServerIpOrHostName = "192.168.1.250"
$jsonFilePath = "C:\temp\json.json"
Connect-WUGServer -serverUri $ServerIpOrHostName -Credential $Credential
$Dashboard = Get-WUGDevices -SearchValue "192.168.1." -View card | Where-Object{$_.downActiveMonitors -ne $null} | Select-Object id, name, networkAddress, hostName, downActiveMonitors | ConvertTo-Json | Out-File $jsonFilePath -Force
$templateFilePath = ".\examples\Bootstrap-Table-Sample.html"
$outputFilePath = "C:\temp\Example-Custom-Report.html"
$customPlaceholder = 'replaceThisHere'
Convert-HTMLTemplate -TemplateFilePath $templateFilePath -JsonFilePath $jsonFilePath -OutputFilePath $outputFilePath -Placeholder $customPlaceholder -ReportName "Down Active Monitor Details"