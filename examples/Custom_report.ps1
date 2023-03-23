if(!$Credential){
    $Credential = Get-Credential
}
$ServerIpOrHostName = "192.168.17.23"
Connect-WUGServer -serverUri $ServerIpOrHostName -Credential $Credential
$Dashboard = Get-WUGDevices -SearchValue "192.168.1." -View card | Where-Object{$_.downActiveMonitors -ne $null} 
$Dashboard | Select-Object id, name, totalActiveMonitors, totalActiveMonitorsDown, notes, hostName, networkAddress, bestState, worstState, @{Name='downActiveMonitorsDetails'; Expression={($_.downActiveMonitors | ForEach-Object { $_.state + " (" + $_.reason + "; " + $_.lastChangeUtc + "; " + $_.monitorTypeName + "; " + $_.comment + "; " + $_.enabled + ")" }) -join ', '}} | ConvertTo-Html -Title "Dashboard Report" -PreContent "<h1>Dashboard Report</h1>" | Set-Content -Path "C:\temp\DashboardReport.html"