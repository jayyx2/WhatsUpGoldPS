# BGP Monitoring Helper

Standalone BGP peer inventory, Cisco SSH collection, SNMP Table monitor planning, and combined dashboard export for WhatsUp Gold.

```powershell
. .\Get-BgpPeerInventory.ps1
$peers = Get-BgpPeerInventory -Target 10.0.0.1 -Community public
$peers | Format-Table PeerAddress, RemoteAs, State, EstablishedSeconds, Status
```

`Invoke-BgpMonitoring.ps1` collects peers, writes `bgp-peers.json` and `bgp-dashboard.html`, and can create one dynamic SNMP Table adjacency monitor plus per-peer state and established-time performance monitors with `-CreateWugMonitors`. Use `-OidMap` for vendor-specific MIB layouts.

Use `-UseSsh` with a `PSCredential` to add Cisco IOS, IOS-XE, or NX-OS data from `show ip bgp summary`, `show ip bgp`, and `show ip bgp neighbors`. Matching SNMP peers are enriched with SSH state, prefixes, message counters, uptime, and neighbor detail; route and summary rows are included in the same dashboard.

```powershell
$ssh = Get-Credential
.\Invoke-BgpMonitoring.ps1 -Target 10.0.0.1 -DeviceId 42 -UseSsh -SshCredential $ssh
```
