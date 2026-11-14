# Discovery Providers — A Plain-English Guide

## What Is This?

WhatsUp Gold (WUG) is software that monitors your servers, cloud resources, and network equipment to make sure everything is running. But before it can monitor anything, it needs to **know what exists** — and that's where **discovery providers** come in.

Think of it like this:

> **WhatsUp Gold** = the security guard watching your building's cameras  
> **Discovery providers** = the person who goes around and installs cameras in every room first

Each discovery provider knows how to talk to a specific platform (Azure, AWS, VMware, etc.), find all the resources on it, and then either:

- **Add them to WhatsUp Gold** so they get monitored automatically, or
- **Generate an HTML report** (a dashboard) you can open in your browser

---

## What Platforms Are Supported?

For a Zabbix server, use the separate
[guided Zabbix-to-WUG wizard](../helpers/converters/README.md), not a discovery
provider setup script. From the repository root:

```powershell
.\examples\Import-ZabbixHostsToWUG.ps1
```

It selects Zabbix groups/hosts, reads effective configuration, prompts for missing
credential secrets, and can create/reuse WUG devices, library monitors and
approved assignments after final **APPLY** confirmation. `-WhatIf` performs
source-only discovery; saved redacted selections can be resumed with `-PlanPath`.
It uses the discovery framework's vault but is **not** a provider in the table below.

This is an experimental, selective migration: supported raw SNMP snapshots/trap
filters and reviewed Ping/TCP/restricted HTTP/current-value alternatives are not
a complete copy of Zabbix. SSH/SQL, agent checks and advanced HTTP need reviewed
existing WUG replacements; transforms, complex alert logic, dynamic LLD lifecycle,
history, dashboards and actions are not migrated. Credential discovery/creation
does not imply that the corresponding monitor is converted. See the
[coverage and credential limits](../helpers/converters/README.md#4-credential-discovery-and-safety).
Assignment read-back is not live authentication or polling validation.

For **local Zabbix export files**, the
[offline SNMP template converter](zabbix-template-conversion.md) remains separate.
It generates profiles/reports and optionally creates supported SNMP active,
performance, table and trap monitors in the WUG library; that converter does
not create devices or assign monitors.

| Provider | What It Scans |
|----------|--------------|
| **Azure** | Virtual machines, databases, app services, and other cloud resources in Microsoft Azure |
| **AWS** | EC2 instances, RDS databases, and other resources in Amazon Web Services |
| **GCP** | Compute instances and resources in Google Cloud Platform |
| **OCI** | Compute and resources in Oracle Cloud Infrastructure |
| **VMware** | Virtual machines running on VMware vSphere / ESXi hosts |
| **Hyper-V** | Virtual machines running on Microsoft Hyper-V hosts |
| **Proxmox** | Virtual machines and containers on Proxmox VE servers |
| **Nutanix** | VMs and clusters on Nutanix AHV |
| **Docker** | Containers running on Docker hosts |
| **F5** | Virtual servers and pools on F5 BIG-IP load balancers |
| **LoadMaster** | Virtual services on Kemp LoadMaster load balancers |
| **Fortinet** | Interfaces, VPNs, and health on FortiGate firewalls |
| **Bigleaf** | SD-WAN circuits and tunnel health on Bigleaf Networks devices |
| **Windows Attributes** | OS, hardware, BIOS, and memory info as device attributes on Windows servers |
| **Windows Disk I/O** | Disk instance discovery and disk I/O performance monitors on Windows servers |
| **Linux** | SSH compliance checks, shared health/performance monitors, OS classification and inventory attributes |
| **NVIDIA GPU** | GPUs on Linux hosts via `nvidia-smi` over SSH: GPU Health, per-GPU metrics, and inventory attributes |
| **Redfish** | Server hardware health, power, and thermals through BMCs (iLO, iDRAC, XCC, Supermicro) |

---

## How Does It Work? (The Big Picture)

The whole process has four steps:

```
Step 1          Step 2           Step 3            Step 4
Enter your      Scan the         Build a list      Do something
credentials  →  platform for  →  of everything  →  with the results
(passwords,     all resources    that was found    (monitor it, make
API keys)       and metrics                        a report, etc.)
```

### Step 1 — Credentials

Every platform needs a login. You'll be asked for things like:

- **Azure**: A Service Principal (app ID + secret)
- **AWS**: An Access Key + Secret Key
- **VMware / Proxmox**: A username + password or API token
- **Docker**: An API token
- **NVIDIA GPU**: An SSH username + password (no root or sudo needed)
- **Linux**: An SSH username + password for WUG monitoring; key-only runs can collect inventory and validate commands

Your credentials are saved in an **encrypted vault** on your computer — they're never stored in plain text. Only your Windows user account can decrypt them. If you run the setup again later, it will find your saved credentials so you don't have to type them again.

### Step 2 — Scanning

The provider connects to the platform's API and looks for everything:

- What servers/VMs/containers exist?
- What metrics are available for each one? (CPU, memory, disk, health status, etc.)
- Are those metrics actually returning real data? (It tests them to make sure)

The Linux and NVIDIA helpers can run `-Action Validate` without touching WUG. Pushes run the
same checks before provisioning: command failures, empty results and malformed numbers are
excluded. A health command that successfully reports an unhealthy host is still eligible,
so WUG can alert on the fault.

### Safe repeat runs

Shared WUG synchronization reuses both active and performance library entries, reads every
assignment page, and adds only missing assignments. A failed assignment lookup prevents writes
for that device/type rather than being mistaken for an empty list.

Inventory synchronization compares values before writing, preserves last-known values when a
new value is null/blank, and keeps zero/false as valid values. It reports written, unchanged and
failed counts. Proxmox and Docker refresh attributes on existing devices as well as new ones.
If a Proxmox cluster endpoint shares a WUG device with a physical node, their inventory is merged
once; node classification takes precedence while cluster-only facts are retained.
VMware and Hyper-V do not copy a no-IP guest's inventory onto its host's WUG device.
No stale attributes or legacy monitor assignments are automatically deleted.

Docker hosts with no running containers still receive host health monitoring and inventory,
including their actual address and a zero container count. Container performance monitors
track memory usage in bytes and eth0 network Rx/Tx bytes, not CPU percentage. Older monitors
named `CPU Usage` actually read memory usage; review those legacy assignments manually.
These anonymous REST monitors need no WUG REST credential. Restrict access to the Docker
API to trusted pollers rather than exposing its host-control endpoints broadly.

### Hyper-V prerequisites and validation

Hyper-V discovery uses WSMan, then DCOM/WMI fallback. Local Hyper-V RSAT is optional.
Allow the chosen management transport and supply an account with the required host/WMI
permissions. `Setup-HyperV-Discovery.ps1 -HyperVCredential $credential` accepts an existing
vault's PSCredential without copying it into the discovery vault. WUG pushes create/reuse
one account-named Windows credential and assign it to the resolved devices before monitors.
Existing devices are matched by address, then exact hostname/name; their addresses are not
silently changed.

Host monitors check VMMS and, on cluster nodes, ClusSvc without restarting either service.
Host performance counters report CPU %, available memory in MB, and disk free %.
VM status queries `root\virtualization\v2` by GUID. VM CPU averages all matching virtual
processors; missing samples fail rather than report zero. VM memory uses PhysicalMemory
in MB. PowerShell scripts retrieve the assigned Windows credential from WUG's runtime
context and pass it explicitly to remote WMI; impersonation alone is insufficient.
Unavailable VM inventory remains unknown instead of becoming a fabricated zero.

Clustered VM status, CPU, and memory scripts resolve `MSCluster_Resource.PrivateProperties.VmId`
to the current owner on every poll. Parallel probes use the known node addresses with a
20-second ownership deadline; failed probes are reported, and unresolved ownership fails
explicitly rather than using a stale owner. Allow remote WMI/DCOM access to `root\MSCluster`,
`root\virtualization\v2`, and the performance classes on every node from the WUG poller.

VMs with an IP keep their own WUG device. No-IP clustered VMs keep their checks on the
alphabetically first cluster node's WUG device, independent of the current VM owner.
Rediscovery therefore reuses assignments instead of adding them to each successive owner.
VM inventory still never overwrites host inventory. The assignment itself does not move:
review WUG dependencies/polling policies if an anchor-device outage could suppress checks.

**Existing deployments:** push the new `HyperV - Cluster VM ... [GUID]` monitors, verify
their results, then review and unassign the old `HyperV - VM ...` static-owner monitors.
Neither legacy configurations nor assignments are silently rewritten/deleted. Standalone
VM checks still use their discovered host. Rediscovery does not update an existing
library monitor's configuration.

Live validation covered two-node host-service polling, WUG-executed numeric host/VM
metrics, and a temporary diskless VM's Running -> Off -> Running status. A separate
temporary clustered VM live-migrated in both directions (VMMS event 20415; reported
blackout 4.5 and 2.2 seconds). A resource-scoped `Test-ClusterResourceFailure`, with only
the temporary VM resource's restart threshold temporarily changed, automatically recovered
the VM Running/Online on the other node in about 14 seconds. WUG status and exact CPU/memory
scripts followed ownership without library/assignment edits; a controlled role Offline/Online
cycle verified fresh Down -> Up results. Repeated setup reused devices/libraries and
preserved assignment IDs/settings. Temporary VMs, roles, and test-only monitors were removed.

This was a simulated VM-resource failure, not a physical-node outage. Both nested nodes
share a physical failure domain; the diskless fixture does not establish guest application
continuity. Physical-host failure remains unvalidated.

Historical host-counter ingestion was separately verified through WUG's Custom Performance
Monitors report and its rendered charts, not just active-monitor metric verifiers or the
last-polled table. All six assignments (CPU %, available memory MB, and disk free % on both
hosts) had multiple distinct timestamped numeric samples spanning more than an hour.
Requesting one additional real device poll added a newer historical sample to every series;
the charts were checked against the persisted report data. Constant disk-free values still
produced distinct timestamped samples, rather than being mistaken for missing collection.
No monitor configuration, polling interval, or VM was changed for this check.

To inspect these graphs, open the device's Custom Performance Monitors report, choose
Today or an appropriate historical range, and select an individual monitor. Avoid mixing
MB, percentages, and byte counters on one axis when checking a particular series.
Match both the device and custom monitor name: the standard CPU/memory reports can show
different collectors on the same device. The public REST report functions do not expose
these custom-monitor charts; this validation used the authenticated WUG console.

Per-VM historical charts were not part of this host-counter check because the temporary
VMs and their monitors had already been removed. Long-term retention/rollups also remain
outside the validated scope.

### Step 3 — The Discovery Plan

The scan produces a **plan** — a list of items like:

> "Create a health monitor for VM `web-server-01` that checks if it's running"  
> "Create a CPU monitor for VM `db-server-03` that tracks its processor usage"

Each item includes the monitor name, what URL to check, what value to look for, and which device it belongs to.

### Step 4 — Taking Action

You choose what to do with the plan:

| Action | What Happens |
|--------|-------------|
| **Push to WUG** | Automatically creates devices, credentials, and monitors inside WhatsUp Gold. Everything starts monitoring immediately. |
| **Dashboard** | Generates a self-contained HTML file you can open in any browser. It has search, sorting, filtering, and export buttons. No WhatsUp Gold needed. |
| **Both** | Makes the dashboard AND pushes to WUG. |
| **Export to JSON/CSV** | Saves the plan as a data file you can review or import later. |
| **Show Table** | Just prints the results in your PowerShell console so you can look at them. |
| **None** | Dry run — scans but does nothing with the results. Good for testing. |

---

## How Do I Run It?

### Option A — The Multi-Provider Launcher

Run this in PowerShell:

```powershell
.\helpers\discovery\Start-WUGDiscoverySetup.ps1
```

It will show you a menu of all available providers and walk you through the setup interactively.

### Option B — Run a Specific Provider Directly

Each provider has its own setup script. For example:

```powershell
# Azure
.\helpers\discovery\Setup-Azure-Discovery.ps1

# VMware
.\helpers\discovery\Setup-VMware-Discovery.ps1

# Proxmox
.\helpers\discovery\Setup-Proxmox-Discovery.ps1
```

The setup script will prompt you for everything it needs.

### Option C — Schedule It to Run Automatically

You can register a Windows Scheduled Task so discovery runs on a timer (e.g., every night at 2 AM):

```powershell
.\helpers\discovery\Register-DiscoveryScheduledTask.ps1
```

This is useful for keeping WhatsUp Gold in sync when VMs are constantly being created or destroyed.

---

## What Gets Created in WhatsUp Gold?

When you choose "Push to WUG," here's what happens behind the scenes:

1. **Credentials** are created in WUG (so it can authenticate to the cloud/platform API)
2. **Devices** are created for each discovered resource (server, VM, container, etc.)
3. **Active monitors** are attached — these check "is it up or down?"
4. **Performance monitors** are attached — these collect numeric data like CPU %, memory usage, response time
5. **Device attributes** are set — tags like subscription ID, resource group, cloud region, etc.

You don't need to manually configure any of this. The discovery provider handles it all.

---

## What Does the Dashboard Look Like?

The HTML dashboard is a standalone web page (no server needed) that includes:

- **Summary cards** at the top showing totals and breakdowns
- **A searchable, sortable table** with all discovered items
- **Color coding** — green/yellow/red based on health or thresholds
- **Export buttons** — download the data as CSV, Excel, JSON, or even a PNG image

You can open it in any browser, email it to someone, or put it on a shared drive.

---

## Credential Vault — Where Are My Passwords Stored?

All credentials are saved here on your computer:

```
%LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Vault\
```

They are encrypted using **Windows DPAPI**, which means:

- Only **your** Windows user account can decrypt them
- They cannot be read on another computer or by another user
- If you need to change a credential, re-run the setup and choose "Reset" when prompted

---

## Frequently Asked Questions

**Q: Do I need WhatsUp Gold installed to use this?**  
A: Not for dashboards or exports. You only need a WUG server if you want to push monitors into it.

**Q: What if I add new VMs after running discovery?**  
A: Run it again. The system checks for duplicates — it won't create duplicate monitors for things that already exist in WUG.

**Q: Can I run this for multiple Azure subscriptions / AWS accounts?**  
A: Yes. Each run can target multiple subscriptions or accounts. The setup will prompt you or you can pass them as parameters.

**Q: What version of PowerShell do I need?**  
A: PowerShell 5.1 (which comes with Windows 10/11 and Windows Server 2016+). PowerShell 7 also works.

**Q: Something went wrong. How do I see what happened?**  
A: Run the setup script with `-Verbose` for detailed output. The discovery scripts also write warnings and errors to the console.

---

## Summary

| Concept | One-Liner |
|---------|-----------|
| **Discovery provider** | A plugin that knows how to scan one specific platform |
| **Setup script** | A wizard that walks you through configuring and running a provider |
| **Credential vault** | Encrypted local storage for your API keys and passwords |
| **Discovery plan** | The list of monitors and devices the scan wants to create |
| **Push to WUG** | Automatically creates everything in WhatsUp Gold |
| **Dashboard** | A standalone HTML report of what was found |
