# Discovery Vault & Scheduled Task Setup Guide

Complete step-by-step instructions for every discovery provider — vault setup, test run, and scheduling.

---

## Prerequisites

1. **Run all commands from an elevated (Administrator) PowerShell prompt.**  
   The LocalMachine DPAPI vault requires admin rights. Scheduled tasks running as SYSTEM require admin rights to register.

2. **Navigate to the discovery folder first:**
   ```powershell
   cd "T:\OneDrive\GitHub\WhatsUpGoldPS\helpers\discovery"
   ```

3. **One-time setup wizard (optional, covers everything interactively):**
   ```powershell
   .\Start-WUGDiscoverySetup.ps1
   ```
   This wizard guides you through all providers, saves credentials to the vault, and schedules tasks.

---

## How It Works

```
┌─────────────────────────────────────────────────┐
│  Step 1: Initialize-WUGDiscoveryVault.ps1        │
│  → Asks for credentials once                     │
│  → Saves encrypted to LocalMachine DPAPI vault   │
│  → Any admin / SYSTEM process can decrypt later  │
└───────────────────┬─────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────┐
│  Step 2: Register-DiscoveryScheduledTask.ps1     │
│  → Registers task running as SYSTEM              │
│  → Task reads vault credentials automatically    │
│  → -RunNow tests it immediately                  │
└───────────────────┬─────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────┐
│  Result: Dashboard HTML in                       │
│  C:\ProgramData\WhatsUpGoldPS\Output\            │
│  Updated every time the task fires (daily 2 AM)  │
└─────────────────────────────────────────────────┘
```

The vault stores credentials in `C:\ProgramData\WhatsUpGoldPS\Vault\` encrypted with the Windows machine key. SYSTEM and any administrator on the same machine can decrypt them — no passwords stored in plain text, no credentials in task definitions.

---

## Provider Reference

Jump to any provider:
- [Azure](#azure)
- [AWS](#aws)
- [Proxmox](#proxmox)
- [LoadMaster](#loadmaster)
- [Windows Attributes](#windows-attributes)
- [Windows Disk IO](#windows-disk-io)
- [Cisco WLC](#cisco-wlc)
- [Cisco CUCM](#cisco-cucm)
- [Hyper-V](#hyper-v)
- [VMware](#vmware)
- [Nutanix](#nutanix)
- [F5 BIG-IP](#f5-big-ip)
- [Fortinet FortiGate](#fortinet-fortigate)
- [Docker](#docker)
- [Bigleaf](#bigleaf)
- [GCP](#gcp)
- [OCI](#oci)

---

## Azure

**What you need:** An App Registration (Service Principal) with Reader role on the subscription(s).

**Find credentials:** Azure Portal → App Registrations → your app → Certificates & Secrets

### Step 1 — Save credentials to vault
```powershell
.\Initialize-WUGDiscoveryVault.ps1 -Providers Azure
# Prompts:
#   Tenant ID      : f7b2ef38-1a73-44e0-9b44-ae4d09864721
#   Client ID      : c437ba98-8d2d-4f41-89a5-d4d4ebe7141c
#   Client Secret  : (your secret, hidden)
```

### Step 2 — Test run (verify dashboard generates)
```powershell
.\Setup-Azure-Discovery.ps1 -TenantId '<tenant-id>' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule daily at 2 AM
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Azure -Target '<tenant-id>' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\Azure-Dashboard.html`

**Re-run anytime:**
```powershell
.\Setup-Azure-Discovery.ps1 -Action Dashboard -NonInteractive
```

---

## AWS

**What you need:** IAM Access Key + Secret Key with EC2/RDS/ELB read permissions.

**Find credentials:** AWS Console → IAM → Users → your user → Security credentials → Access keys

### Step 1 — Save credentials to vault
```powershell
.\Initialize-WUGDiscoveryVault.ps1 -Providers AWS
# Prompts:
#   Access Key ID      : AKIA...
#   Secret Access Key  : (hidden)
#   Region(s)          : all  (or: us-east-1,eu-west-1)
```

### Step 2 — Test run
```powershell
.\Setup-AWS-Discovery.ps1 -Region all -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider AWS -Target 'all' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\AWS-Dashboard.html`

**Specific regions:**
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider AWS -Target 'us-east-1','eu-west-1' -Action Dashboard -UseSystemVault -SkipVaultPopulate -RunNow
```

---

## Proxmox

**What you need:** Proxmox API Token (recommended) or username + password.

**Find credentials:** Datacenter → Permissions → API Tokens → Add  
Token format: `user@realm!tokenname=<uuid>` (e.g., `root@pam!discovery=abc123...`)

### Step 1 — Save credentials to vault (API Token)
```powershell
.\Initialize-WUGDiscoveryVault.ps1 -Providers Proxmox
# Prompts:
#   Proxmox host       : 192.168.1.30
#   Auth method [1]    : 1  (API Token)
#   API Token (hidden) : root@pam!whatsupgoldps=6470f043-...
```

### Step 2 — Test run
```powershell
.\Setup-Proxmox-Discovery.ps1 -Target '192.168.1.30' -AuthMethod Token -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Proxmox -Target '192.168.1.30' -AuthMethod Token -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\Proxmox-Dashboard.html`

**Multiple Proxmox hosts:**
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Proxmox -Target '192.168.1.30','192.168.1.31' -AuthMethod Token -Action Dashboard -UseSystemVault -SkipVaultPopulate -RunNow
```

---

## LoadMaster

**What you need:** API Key (recommended) or bal:password credentials.

**Find API Key:** LoadMaster web UI → System → Certificates & Security → API Security → Enable API Access

### Step 1 — Save credentials to vault (API Key)
```powershell
.\Initialize-WUGDiscoveryVault.ps1 -Providers LoadMaster
# Prompts:
#   LoadMaster host(s) : 192.168.1.103
#   Auth method [1]    : 1  (API Key)
#   API Key (hidden)   : S7IKk...
```

### Step 2 — Test run
```powershell
.\Setup-LoadMaster-Discovery.ps1 -Target '192.168.1.103' -AuthMethod ApiKey -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider LoadMaster -Target '192.168.1.103' -AuthMethod ApiKey -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\LoadMaster-Dashboard.html`

---

## Windows Attributes

Collects 36 hardware/OS/software attributes from Windows hosts via WMI.

**What you need:** Local administrator or domain admin credentials for the target hosts.

**Note:** Credentials are tried in order (1, 2, 3...) until one succeeds. Add multiple for different domains/subnets.

### Step 1 — Save credentials to vault
```powershell
.\Initialize-WUGDiscoveryVault.ps1 -Providers Windows
# Prompts:
#   Windows host(s)        : 192.168.75.33
#   Credential #1 Username : .\Administrator   (or DOMAIN\User)
#   Credential #1 Password : (hidden)
#   Add another? [y/N]     : y
#   Credential #2 Username : WUGNINJA\JASON
#   Credential #2 Password : (hidden)
```

### Step 2 — Test run
```powershell
.\Setup-WindowsAttributes-Discovery.ps1 -Target '192.168.75.33' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider WindowsAttributes -Target '192.168.75.33' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\WindowsAttributes-Dashboard.html`

**Multiple targets:**
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider WindowsAttributes -Target '192.168.75.33','192.168.74.74','192.168.1.100' -Action Dashboard -UseSystemVault -SkipVaultPopulate -RunNow
```

**Vault keys:** `Windows.WMI.Credential.1`, `Windows.WMI.Credential.2`, etc.

---

## Windows Disk IO

Same as Windows Attributes but focuses on disk performance metrics and generates disk IO monitors for WUG. **Shares the same WMI credentials** as Windows Attributes — no separate vault entry needed if already set up.

### Test run (after Windows Attributes vault is populated)
```powershell
.\Setup-WindowsDiskIO-Discovery.ps1 -Target '192.168.75.33' -Action Dashboard -NonInteractive
```

### Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider WindowsDiskIO -Target '192.168.75.33' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:30' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\WindowsDiskIO-Dashboard.html`

---

## Cisco WLC

Discovers APs, clients, WLANs, and RF health via SNMP walk of the Cisco WLC MIB.

**What you need:** SNMP v2c community string or SNMP v3 credentials for the WLC.

**Tip:** Use an SNMP simulator (e.g., SNMP Spyder) at a known IP to test without a real WLC.

### Step 1 — Save SNMP credentials to vault

**SNMPv2c:**
```powershell
.\Initialize-WUGDiscoveryVault.ps1 -Providers CiscoWLC
# Prompts:
#   WLC host(s)        : 192.168.75.33
#   SNMP version [1]   : 1      (press Enter = v2c)
#   Community string   : public
```

**SNMPv3:**
```powershell
.\Initialize-WUGDiscoveryVault.ps1 -Providers CiscoWLC
# Prompts:
#   WLC host(s)        : 192.168.75.33
#   SNMP version [1]   : 2      (SNMPv3)
#   Username           : wugninja
#   Context            : (blank)
#   Auth protocol [2]  : 2  (SHA)
#   Auth password      : (hidden)
#   Privacy protocol   : 2  (AES128)
#   Privacy password   : (hidden)
```

### Step 2 — Test run
```powershell
.\Setup-CiscoWLC-Discovery.ps1 -Target '192.168.75.33' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider CiscoWLC -Target '192.168.75.33' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboards:** `C:\ProgramData\WhatsUpGoldPS\Output\summary\dashboards\wireless-dashboard-*.html`

**Vault key:** `CiscoWLC.Snmp`

---

## Cisco CUCM

Walks the `ccmPhoneTable` MIB on the CUCM publisher to inventory registered IP phones.

**What you need:** SNMP v2c or v3 credentials configured on the CUCM.

**Important:** If sharing a host with CiscoWLC (e.g., SNMP Spyder), load the CUCM MIB profile before running.

### Step 1 — Save SNMP credentials to vault
```powershell
.\Initialize-WUGDiscoveryVault.ps1 -Providers CUCM
# Prompts:
#   CUCM host(s)       : 192.168.75.33
#   SNMP version [1]   : 1      (v2c)
#   Community string   : public
```

### Step 2 — Test run
```powershell
.\Setup-CUCM-Discovery.ps1 -Target '192.168.75.33' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider CUCM -Target '192.168.75.33' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Vault key:** `CUCM.Snmp`

---

## Hyper-V

Discovers VMs on Microsoft Hyper-V hosts via WMI/CIM.

**What you need:** Administrator credentials on the Hyper-V host (or domain admin).

### Step 1 — Save credentials to vault
```powershell
.\Setup-HyperV-Discovery.ps1 -Target '192.168.1.50' -Action None
# Follow prompts to save PSCredential to vault
```

Or interactively via the wizard:
```powershell
.\Start-WUGDiscoverySetup.ps1
# Select: HyperV
```

### Step 2 — Test run
```powershell
.\Setup-HyperV-Discovery.ps1 -Target '192.168.1.50' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider HyperV -Target '192.168.1.50' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\HyperV-Dashboard.html`

---

## VMware

Discovers VMs on VMware vCenter or standalone ESXi via the vSphere REST API.

**What you need:** Read-only vSphere credentials (vCenter or ESXi admin).

### Step 1 — Save credentials to vault
```powershell
.\Setup-VMware-Discovery.ps1 -Target '192.168.1.60' -Action None
# Follow prompts to save PSCredential to vault
```

### Step 2 — Test run
```powershell
.\Setup-VMware-Discovery.ps1 -Target '192.168.1.60' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider VMware -Target '192.168.1.60' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\VMware-Dashboard.html`

---

## Nutanix

Discovers VMs and cluster health on Nutanix AHV via Prism Central REST API.

**What you need:** Prism Central admin or viewer credentials (port 9440).

### Step 1 — Save credentials to vault
```powershell
.\Setup-Nutanix-Discovery.ps1 -Target '192.168.1.70' -Action None
# Follow prompts to save PSCredential to vault
```

### Step 2 — Test run
```powershell
.\Setup-Nutanix-Discovery.ps1 -Target '192.168.1.70' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Nutanix -Target '192.168.1.70' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\Nutanix-Dashboard.html`

---

## F5 BIG-IP

Discovers virtual servers, pools, and real servers via the iControl REST API.

**What you need:** F5 credentials with iControl REST access (admin or resource-admin role).

### Step 1 — Save credentials to vault
```powershell
.\Setup-F5-Discovery.ps1 -Target '192.168.1.80' -Action None
# Follow prompts to save PSCredential to vault
```

### Step 2 — Test run
```powershell
.\Setup-F5-Discovery.ps1 -Target '192.168.1.80' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider F5 -Target '192.168.1.80' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\F5-Dashboard.html`

---

## Fortinet FortiGate

Discovers firewall policies, interfaces, VPN tunnels, and HA status via REST API token.

**What you need:** REST API token from FortiGate (System → Administrators → REST API Admin).

### Step 1 — Save token to vault
```powershell
.\Setup-Fortinet-Discovery.ps1 -Target '192.168.1.1' -Action None
# Follow prompts to save BearerToken to vault
```

### Step 2 — Test run
```powershell
.\Setup-Fortinet-Discovery.ps1 -Target '192.168.1.1' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Fortinet -Target '192.168.1.1' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\Fortinet-Dashboard.html`

---

## Docker

Discovers containers and images via the Docker Engine REST API.

**What you need:** Docker API exposed on port 2375 (no credentials needed for unauthenticated API).

### Step 1 — No vault setup required
Docker uses unauthenticated local API. Ensure the Docker host has API access enabled:
```
# On the Docker host, enable API:
# Edit /etc/docker/daemon.json:
# { "hosts": ["tcp://0.0.0.0:2375", "unix:///var/run/docker.sock"] }
```

### Step 2 — Test run
```powershell
.\Setup-Docker-Discovery.ps1 -Target '192.168.1.90' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Docker -Target '192.168.1.90' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\Docker-Dashboard.html`

---

## Bigleaf

Discovers SD-WAN sites and tunnels via the Bigleaf cloud API.

**What you need:** Bigleaf portal username + password (portal.bigleaf.net).

### Step 1 — Save credentials to vault
```powershell
.\Setup-Bigleaf-Discovery.ps1 -Target 'bigleaf' -Action None
# Follow prompts to save PSCredential to vault
```

### Step 2 — Test run
```powershell
.\Setup-Bigleaf-Discovery.ps1 -Target 'bigleaf' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Bigleaf -Target 'bigleaf' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\Bigleaf-Dashboard.html`

---

## GCP

Discovers Compute Engine instances and cloud resources in Google Cloud Platform.

**What you need:** Service account JSON key file with Compute Viewer role.

### Step 1 — Save key file path to vault
```powershell
.\Setup-GCP-Discovery.ps1 -Target 'my-project-id' -Action None
# Follow prompts to save key file path to vault
```

### Step 2 — Test run
```powershell
.\Setup-GCP-Discovery.ps1 -Target 'my-project-id' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider GCP -Target 'my-project-id' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\GCP-Dashboard.html`

---

## OCI

Discovers compute instances and resources in Oracle Cloud Infrastructure.

**What you need:** OCI config file (`~/.oci/config`) with API signing key.

### Step 1 — Save OCI config to vault
```powershell
.\Setup-OCI-Discovery.ps1 -Target '<tenancy-ocid>' -Action None
# Follow prompts to save OCI config path to vault
```

### Step 2 — Test run
```powershell
.\Setup-OCI-Discovery.ps1 -Target '<tenancy-ocid>' -Action Dashboard -NonInteractive
```

### Step 3 — Schedule
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider OCI -Target '<tenancy-ocid>' -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Daily -TimeOfDay '02:00' -RunNow
```

**Dashboard:** `C:\ProgramData\WhatsUpGoldPS\Output\OCI-Dashboard.html`

---

## Common Operations

### View all registered tasks
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Show
```

### Remove a task
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Remove 'DiscoverySync-Azure'
```

### Manually trigger a task
```powershell
Start-ScheduledTask -TaskName 'DiscoverySync-Proxmox' -TaskPath '\WhatsUpGoldPS\'
```

### View the latest log for a provider
```powershell
Get-ChildItem 'C:\ProgramData\WhatsUpGoldPS\Output\logs' | Where-Object Name -Like 'DiscoverySync-Azure*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
```

### Verify vault credential is saved
```powershell
# Dot-source DiscoveryHelpers, then:
. .\DiscoveryHelpers.ps1
Set-DiscoveryVaultScope -Scope LocalMachine
Get-DiscoveryCredential -Name 'Azure.f7b2ef38-....ServicePrincipal' -ShowRedacted
```

### Schedule hourly instead of daily
```powershell
.\Register-DiscoveryScheduledTask.ps1 -Mode Provider -Provider Proxmox -Target '192.168.1.30' -AuthMethod Token -Action Dashboard -UseSystemVault -SkipVaultPopulate -TriggerType Hourly -RepeatIntervalMinutes 60
```

### Re-run all providers as a batch
```powershell
$providers = @(
    @{ Provider='Azure';            Target='<tenant-id>';    Extra=@{} }
    @{ Provider='AWS';              Target='all';            Extra=@{} }
    @{ Provider='Proxmox';          Target='192.168.1.30';   Extra=@{ AuthMethod='Token' } }
    @{ Provider='LoadMaster';       Target='192.168.1.103';  Extra=@{ AuthMethod='ApiKey' } }
    @{ Provider='WindowsAttributes';Target='192.168.75.33';  Extra=@{} }
    @{ Provider='CiscoWLC';         Target='192.168.75.33';  Extra=@{} }
    @{ Provider='CUCM';             Target='192.168.75.33';  Extra=@{} }
)
foreach ($p in $providers) {
    $args = @{
        Mode              = 'Provider'
        Provider          = $p.Provider
        Target            = @($p.Target)
        Action            = 'Dashboard'
        UseSystemVault    = $true
        SkipVaultPopulate = $true
        RunNow            = $true
    }
    foreach ($k in $p.Extra.Keys) { $args[$k] = $p.Extra[$k] }
    & .\Register-DiscoveryScheduledTask.ps1 @args
}
```

### Copy dashboards to WUG web console
```powershell
# Run on WUG server (or specify UNC path from here):
.\Copy-WUGDashboardReports.ps1 -SourcePath 'C:\ProgramData\WhatsUpGoldPS\Output' -Register -TriggerType Hourly -RepeatIntervalMinutes 30 -RunNow

# Remote WUG server via UNC:
.\Copy-WUGDashboardReports.ps1 -SourcePath 'C:\ProgramData\WhatsUpGoldPS\Output' -Destination '\\wugserver\c$\Program Files (x86)\Ipswitch\WhatsUp\Html\NmConsole'
```

---

## Dashboard Output Locations

| Provider | Dashboard File |
|----------|---------------|
| Azure | `Output\Azure-Dashboard.html` |
| AWS | `Output\AWS-Dashboard.html` |
| Proxmox | `Output\Proxmox-Dashboard.html` |
| LoadMaster | `Output\LoadMaster-Dashboard.html` |
| WindowsAttributes | `Output\WindowsAttributes-Dashboard.html` |
| WindowsDiskIO | `Output\WindowsDiskIO-Dashboard.html` |
| CiscoWLC | `Output\summary\dashboards\wireless-dashboard-index.html` |
| CUCM | `Output\CUCM-PhoneInventory.html` |
| HyperV | `Output\HyperV-Dashboard.html` |
| VMware | `Output\VMware-Dashboard.html` |
| Nutanix | `Output\Nutanix-Dashboard.html` |
| F5 | `Output\F5-Dashboard.html` |
| Fortinet | `Output\Fortinet-Dashboard.html` |
| Docker | `Output\Docker-Dashboard.html` |
| Bigleaf | `Output\Bigleaf-Dashboard.html` |
| GCP | `Output\GCP-Dashboard.html` |
| OCI | `Output\OCI-Dashboard.html` |

All dashboards embed an `Updated:` timestamp in the header, refreshed on every run.

---

## Vault Key Reference

| Provider | Vault Key(s) |
|----------|-------------|
| Azure | `Azure.<TenantId>.ServicePrincipal` |
| AWS | `AWS.Credential` |
| Proxmox | `Proxmox.<host>.Token` or `Proxmox.<host>.Credential` |
| LoadMaster | `LoadMaster.<host>.ApiKey` or `LoadMaster.<host>.Credential` |
| Windows | `Windows.WMI.Credential.1`, `Windows.WMI.Credential.2`, ... |
| CiscoWLC | `CiscoWLC.Snmp` |
| CUCM | `CUCM.Snmp` |
| GCP | `GCP.ServiceAccount` |
| OCI | `OCI.Config` |
| Others | Set via `Setup-<Provider>-Discovery.ps1 -Action None` |

---

*For the full guided interactive experience, run `.\Start-WUGDiscoverySetup.ps1` from an elevated prompt.*
