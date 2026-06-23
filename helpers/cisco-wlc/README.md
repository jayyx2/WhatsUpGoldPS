# Cisco WLC Wireless Helpers

Helper scripts for Cisco wireless controller SNMP data enrichment and dashboard generation. Designed to be copied directly into the [WhatsUpGoldPS](https://github.com/jayyx2/WhatsUpGoldPS) module under `helpers/cisco-wlc/`.

## Contents

```
helpers/cisco-wlc/
├── Build-Wireless-Summaries.ps1       # Enriches raw SNMP exports into inventories & coverage reports
├── Export-Wireless-Dashboard-Pack.ps1 # Generates interactive Bootstrap Table dashboards
├── mibs/                              # Bundled Cisco LWAPP MIB definitions
│   ├── CISCO-LWAPP-AP-MIB.my.txt
│   ├── CISCO-LWAPP-DOT11-CLIENT-MIB.my.txt
│   └── CISCO-LWAPP-WLAN-MIB.my.txt
└── README.md
```

## Dependencies

- PowerShell 5.1+
- `WhatsUpGoldPS.Snmp` module (sibling at `helpers/snmp/WhatsUpGoldPS.Snmp/`)
- `Export-DynamicDashboardHtml` helper from WhatsUpGoldPS (for dashboard rendering)

## Scripts

### Build-Wireless-Summaries.ps1

Reads raw SNMP bulk-walk JSONL exports and produces structured inventories:

- **AP inventory** — MAC, controller addresses, uptime, status
- **Client inventory** — SSID, AP mapping, auth mode, device type
- **WLAN inventory** — profile names with client/AP rollup counts
- **Root-table coverage** — OID/table/variable distribution per MIB root

```powershell
.\Build-Wireless-Summaries.ps1 `
    -InputDirectory C:\temp\wireless-full `
    -OutputDirectory C:\temp\wireless-summary `
    -MibDirectory (Join-Path $PSScriptRoot 'mibs')
```

### Export-Wireless-Dashboard-Pack.ps1

Generates interactive HTML dashboards (Bootstrap Table) from summary JSON:

- Clients, AP Health, WLAN Summary, Coverage, Rogue Tables
- Search/sort/pagination, threshold coloring, cross-dashboard linking
- Export to CSV/JSON/XLSX/PNG

```powershell
.\Export-Wireless-Dashboard-Pack.ps1 `
    -SummaryDirectory C:\temp\wireless-summary `
    -OutputDirectory C:\temp\wireless-summary\dashboards `
    -WhatsUpGoldPsRepoPath T:\OneDrive\GitHub\WhatsUpGoldPS
```

## Integration with WhatsUpGoldPS

When ported, these scripts live at `WhatsUpGoldPS/helpers/cisco-wlc/` and are invoked by the wireless pipeline examples. They depend on:

1. The `WhatsUpGoldPS.Snmp` module for SNMP collection (raw JSONL input)
2. The `Export-DynamicDashboardHtml` function for HTML rendering

## License

See [THIRD-PARTY-NOTICES.txt](../../THIRD-PARTY-NOTICES.txt) and [LICENSE](../../LICENSE) in the repository root.

