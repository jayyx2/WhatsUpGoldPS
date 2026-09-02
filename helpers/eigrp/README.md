# EIGRP Monitoring Helper

This standalone helper queries Cisco `CISCO-EIGRP-MIB` directly and does not register with the discovery framework.

```powershell
. .\Get-EigrpNeighborInventory.ps1
$neighbors = Get-EigrpNeighborInventory -Target 10.0.0.1 -Community public
$neighbors | Format-Table NeighborAddress, InterfaceIndex, HoldTime, SrttMs, Retransmissions, State
```

The orchestrator writes `eigrp-neighbors.json` and `eigrp-dashboard.html`. With `-CreateWugMonitors`, it creates one SNMP Table active monitor for dynamic adjacency rows and per-neighbor SNMP performance monitors for hold time, SRTT, RTO, retransmissions, and retries. Verify the MIB is enabled on the target before using the default OID map; pass a replacement `-OidMap` when a platform exposes a vendor-specific layout.

The optional SSH path runs `show ip eigrp neighbors`, `show ip eigrp topology`, `show ip eigrp interfaces`, `show ip protocols`, and `show ip route eigrp`, then adds the parsed rows to the same dashboard:

```powershell
$ssh = Get-Credential
.\Invoke-EigrpMonitoring.ps1 -Target 10.0.0.1 -DeviceId 42 -UseSsh -SshCredential $ssh
```

SSH collection is read-only and does not create monitors unless `-CreateWugMonitors` is also supplied.