# LLDP Helpers

Collect LLDP neighbors through SNMP or SSH and export a standalone dashboard. The orchestration script resolves credentials from the WhatsUpGoldPS discovery vault.

```powershell
. .\Get-LldpNeighborInventory.ps1
$neighbors = Get-LldpNeighborInventory -Target '192.168.1.1' -Community $community

. .\Export-LldpDashboard.ps1
Export-LldpDashboard -Neighbors $neighbors -OutputDirectory .\output
```

For SSH, use `Invoke-LldpMonitoring.ps1 -UseSsh -SnmpCredentialName 'Cisco.Snmp' -SshCredentialName 'Cisco.Ssh'`.
`New-LldpMonitorPlan.ps1` returns an opt-in WUG SNMP table monitor plan.
