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

Your credentials are saved in an **encrypted vault** on your computer — they're never stored in plain text. Only your Windows user account can decrypt them. If you run the setup again later, it will find your saved credentials so you don't have to type them again.

### Step 2 — Scanning

The provider connects to the platform's API and looks for everything:

- What servers/VMs/containers exist?
- What metrics are available for each one? (CPU, memory, disk, health status, etc.)
- Are those metrics actually returning real data? (It tests them to make sure)

Anything that comes back empty or broken gets filtered out so you don't end up with dead monitors.

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
