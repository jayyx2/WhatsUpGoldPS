#Set your credential
if(!$Credential){
    $Credential = Get-Credential
}
#Enter your server name or IP
$ServerIpOrHostName = "192.168.1.250"
#Enter a filename
$jsonFilePath = "C:\temp\json.json"
#This uses WhatsUpGoldPS Connect-WUGServer function to authenticate
Connect-WUGServer -serverUri $ServerIpOrHostName -Credential $Credential
#This uses WhatsUpGoldPS Get-WUGDevices function to search for monitored devices with "192.168.1." and requests the card view
#It then uses PowerShell's Select-Object to isolate data, converts it to JSON, and outputs to a file
$Dashboard = Get-WUGDevices -SearchValue "192.168.1." -View card | Where-Object{$_.downActiveMonitors -ne $null} | Select-Object id, name, networkAddress, hostName, downActiveMonitors | ConvertTo-Json | Out-File $jsonFilePath -Force
#Where is your HTML template file?
$templateFilePath = ".\examples\Bootstrap-Table-Sample.html"
#What is the file path and name to output?
$outputFilePath = "C:\temp\Example-Custom-Report.html"
#What are we replacing in the file with our $Dashboard data?
$customPlaceholder = 'replaceThisHere'
Convert-HTMLTemplate -TemplateFilePath $templateFilePath -JsonFilePath $jsonFilePath -OutputFilePath $outputFilePath -Placeholder $customPlaceholder -ReportName "Down Active Monitor Details"