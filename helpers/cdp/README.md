# CDP Helpers

Collect Cisco CDP neighbors through SNMP or SSH and export a standalone dashboard. The orchestration script resolves credentials from the WhatsUpGoldPS discovery vault.

```powershell
. .\Get-CdpNeighborInventory.ps1
$neighbors = Get-CdpNeighborInventory -Target '192.168.1.1' -Community $community

. .\Export-CdpDashboard.ps1
Export-CdpDashboard -Neighbors $neighbors -OutputDirectory .\output
```

For SSH, use `Invoke-CdpMonitoring.ps1 -UseSsh -SnmpCredentialName 'Cisco.Snmp' -SshCredentialName 'Cisco.Ssh'`.
`New-CdpMonitorPlan.ps1` returns an opt-in WUG SNMP table monitor plan.
