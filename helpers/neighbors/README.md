# Unified Neighbor Dashboard

`Invoke-NetworkNeighborMonitoring.ps1` collects BGP, EIGRP, CDP, and LLDP evidence and writes one correlated dashboard. Credentials are resolved through the WhatsUpGoldPS discovery vault.

```powershell
. .\Invoke-NetworkNeighborMonitoring.ps1
.\Invoke-NetworkNeighborMonitoring.ps1 -Target '192.168.1.1' -SnmpCredentialName 'Cisco.Snmp' -OutputDirectory .\output
```

Use `-UseSsh -SshCredentialName 'Cisco.Ssh'` to add Cisco CLI evidence. Use `-SkipBgp`, `-SkipEigrp`, `-SkipCdp`, or `-SkipLldp` while testing individual protocol coverage.
