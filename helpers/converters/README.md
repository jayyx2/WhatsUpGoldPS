# Zabbix to WhatsUp Gold: guided operator handoff

Give an operator the complete reviewed repository, connection details through
approved channels, and the command below. No editing scripts, exporting templates
by hand, installing the module, or finding credential IDs is required.

> **Experimental migration planner, not a universal Zabbix runtime.**
> Discovery and mocked workflows are tested on Windows PowerShell 5.1.
> Live Zabbix/WUG validation remains required. Historical data, alert actions,
> dashboards and arbitrary scripts are not migrated.

## 1. The command to hand someone

Place the **complete repository** at `C:\Tools\WhatsUpGoldPS`. Open Windows
PowerShell and paste:

```powershell
& 'C:\Tools\WhatsUpGoldPS\examples\Import-ZabbixHostsToWUG.ps1'
```

Replace that path with the actual installation folder. An absolute path works
from any current directory. From this directory, the equivalent is:

```powershell
& '..\..\examples\Import-ZabbixHostsToWUG.ps1'
```

For a source-only preview that never connects to or changes WUG:

```powershell
& 'C:\Tools\WhatsUpGoldPS\examples\Import-ZabbixHostsToWUG.ps1' -WhatIf
```

The preview still reads Zabbix and prompts for groups, hosts and target interfaces.
It returns redacted definition/credential metadata, not passwords, commands or
monitor payloads. The planner does not write temporary raw exports.

The lower-level [Convert-ZabbixTemplateToWUG.ps1](Convert-ZabbixTemplateToWUG.ps1)
is the **offline file converter**, not the wizard.

## 2. Administrator preparation

| Requirement | Prepare |
|---|---|
| Workstation | Windows PowerShell 5.1 or later, complete trusted repository, readable scripts. |
| Zabbix | Version 6.0-7.4, trusted HTTPS API URL ending in `api_jsonrpc.php`. |
| API permissions | `hostgroup.get`, `host.get`, `template.get`, `usermacro.get`, `item.get`, `trigger.get`, `discoveryrule.get`, `httptest.get`; selected hosts and linked ancestors must be accessible. A denied call stops discovery rather than pretending it returned an empty inventory. |
| Host target | Enabled hosts with a primary interface and literal IPv4 address. Agent-only hosts are supported; DNS/IPv6 targets are blocked by the current WUG device-template contract. With multiple primary interface types, select one WUG target. |
| SNMP | A single primary SNMP interface at the chosen address, literal port, supported protocols. Items on other interfaces are deferred. |
| WUG | Reachable server, normally HTTPS port `9644`, authorized account, read/create device/monitor/credential and assignment permissions. |
| Poller | Network/authentication access to targets, not just workstation access to APIs. |
| Secrets | Missing communities/passwords/cloud keys from an approved channel. A Zabbix API token is not a device credential. |
| Storage | Protect the discovery vault and any saved selection plans. Review existing vault configuration and permissions. |

Example **non-secret** handoff:

```text
Repository:     C:\Tools\WhatsUpGoldPS
Zabbix API:     https://zabbix.example.com/zabbix/api_jsonrpc.php
Groups:         Network / Production
Start with:     switch01
WUG server:     wug.example.com
WUG API port:   9644
Approval:       Review each WUG-native replacement; start with one host
```

Send tokens and passwords separately, not in this checklist, command arguments,
source code or screenshots. Script execution follows your organization's
execution policy and publisher-trust process. Do not disable certificate
validation or edit signature blocks to bypass a trust error.

```powershell
Get-AuthenticodeSignature 'C:\Tools\WhatsUpGoldPS\examples\Import-ZabbixHostsToWUG.ps1' |
    Select-Object Status, StatusMessage
```

## 3. What happens in the wizard

1. Enter a trusted HTTPS Zabbix API URL and masked API token.
2. Pick groups, then hosts by number. **A** selects all listed rows.
   **B** returns from the host picker to groups; **Q** cancels.
3. Select one target interface when necessary. The wizard reads effective host
   items (including resolved discovered items), overrides, triggers, discovery
   rules, web scenarios, linked templates and readable global macro fallbacks.
   Credential macro resolution does not expand arbitrary item keys, OIDs,
   schedules or HTTP URLs for monitor conversion; unresolved monitor fields
   remain deferred.
4. Review the counts. Disabled, transformed or unsupported requirements stay
   visible; they are not quietly replaced.
5. Connect to WUG using the repository's interactive connection helper.
6. Use **M** to review alternatives or choose an existing WUG monitor for an
   unsupported requirement. **X** excludes otherwise ready collectors.
7. Use **C** to inspect credential candidates, reuse/create credentials and
   explicitly approve device assignments. New credential values are staged in
   memory; they are not saved/created yet.
8. **S** saves redacted selections. **B** returns to the review menu;
   **Q** cancels before credential/library/device/assignment writes.
9. **A** performs read-only preflight: device ambiguity, required SNMP bindings,
   WUG supported monitor classes, existing replacement fingerprints and all
   planned library name/configuration conflicts.
   Missing approved monitors or required SNMP bindings return you to review.
   Other preflight conflicts stop the run before wizard writes.
10. Review the final device/monitor/credential tables. Type **APPLY** once to
    save staged credentials to the vault, create credentials and library
    monitors, create only missing devices, and assign approved objects.
11. Inspect returned assignment receipts, then validate actual live polling in WUG.

**Navigation is scoped, not an undo system.** B in the host picker returns to
groups; B at the main review menu keeps the current selections and redisplays
that menu. It does not change the chosen hosts or remove staged credentials,
assignments or existing-monitor replacements. X excludes ready generated
candidates; M can review them again. Restart or cancel and review a fresh plan
to change selections that have no removal option. Saved plans are selection
checkpoints, not unattended jobs or a transactional rollback mechanism.

### Example: groups and hosts

Illustrative values, not real credentials:

```text
Zabbix HTTPS API URL: https://zabbix.example.com/api_jsonrpc.php
Zabbix API token: ********

Number Name          Id
1      Network       12
2      Production    19
Choose Zabbix groups: numbers separated by commas, [A] All, [B] Back, [Q] Cancel: 1,2

Number Name                     Id
1      Core switch [switch01]   10401
2      Application [app01]      10402
Choose Zabbix hosts: ...: 1
```

### Example: monitor review

```text
[M] Review monitor alternatives, [X] Exclude monitors, [C] Review credentials,
[S] Save redacted plan, [A] Apply, [B] Back to review, [Q] Cancel: M

Name: Item 42110
Status: Review
Reasons: WUG-native TCP connection alternative; source trigger semantics require separate review.
Use this explicitly labeled WUG-native alternative for switch01? [Y/N]: Y

Name: Item 42111
Status: Deferred
Reasons: ODBC DSN/query/row semantics are not equivalent to a WUG SQL connection.
Select a reviewed existing WUG monitor for this requirement? [Y/N]: Y
Choose one existing monitor: ...: 3
Reviewed assignment interval in seconds (10-86400): 60
```

Existing replacement monitors are selected deliberately from the WUG library.
Their commands, credentials, thresholds, units and authentication must already
be configured appropriately. Selecting a monitor does not rewrite its contents.
An SSH/SQL monitor may execute a command/query later on the **WUG poller**.
Discovery never executes a Zabbix command, SQL query or script.

### Example: missing credentials

```text
Add a credential type not detected for 'switch01' ...? [Y/N]: N
switch01: SNMP polling; sources: interface 2. Confirm purpose; no secrets are displayed.
Use this credential candidate? [Y/N]: Y
Credential for switch01: number or ID, [C] Create with vault, [U] WUG UI, [R] Refresh, [Q] Cancel: C
New WUG credential name [Zabbix zabbix.example.com 10401 - SNMP]: Production switch SNMP
Use available Zabbix/vault value for SnmpReadCommunity? [Y/N]: N
SnmpReadCommunity: ********
Assign this snmpV2 credential to WUG device 'switch01'? [Y/N]: Y

switch01: ssh item ...; sources: ...
Use this credential candidate? [Y/N]: Y
Credential for switch01: ...: C
New WUG credential name [...]: Production SSH
SshUsername: ********
SshPassword: ********
Assign this ssh credential to WUG device 'switch01'? [Y/N]: N
```

Here SNMP will be assigned; SSH will be created **library-only**.
When another candidate has the same credential type, the wizard offers reuse of
the last reviewed credential, **only with explicit approval**. Similar names
are not automatically merged. Each device can select one credential per type;
additional approved candidates of that type remain library-only.

### Example: final approval and receipts

```text
Type APPLY to save credentials, create devices/monitors and assign approved objects: APPLY

HostId                  : 10401
DeviceId                : 273
CreatedLibraryMonitors  : 3
CreatedAssignments      : 3
AssignedMonitors        : 3
AssignedCredentials     : 1
BlockedDefinitions      : 2
ReviewedReplacements    : 1
AssignmentValidation    : ReadBackVerified
LiveValidation          : NotRun
```

`ReadBackVerified` means WUG returned the selected assignments. It does **not**
mean authentication worked, the poller ran, a response matched, or the alert
condition has been validated. Blocked counts still include requirements handled
by user-selected replacements; replacements are counted separately.
`BlockedDefinitions` counts every non-Ready definition, including disabled,
skipped and unapproved alternatives. It is not solely a count of unsupported
types. `ReviewedReplacements` counts selected requirement-to-monitor mappings;
`AssignedMonitors` counts distinct selected monitor type/ID pairs.

## 4. Credential discovery and safety

| Candidate | Discovery / creation |
|---|---|
| SNMP v1/v2 | Interface community; readable simple macros; masked missing-value prompts. |
| SNMP v3 | Security name/context, auth/privacy secrets and protocols. Automatic creation is authPriv with MD5/SHA1 and DES/AES128 only. Other levels/protocols require a configured existing credential; never downgrade. |
| SSH | Password-authenticated SSH items and `{$SSH.*}` / `{$SSH_*}` setting names. Private-key items surface existing-credential-only choices, never a password downgrade. |
| Windows | `{$WINDOWS.*}`, `{$WIN.*}`, `{$WMI.*}` and underscore equivalents. Confirm `DOMAIN\user` / `.\user` and purpose; agent monitoring does not imply a Windows login. |
| HTTP / REST | HTTP item or web-scenario authentication settings. Create HTTP Basic credentials only; other auth modes must use an intentionally configured existing REST API credential. Headers/tokens are not scraped as passwords. |
| ADO | Database/ODBC item username/password. Does not translate a DSN or configure an SQL connection. |
| AWS | `{$AWS.*}` / underscore settings: ACCESS_KEY_ID/ACCESSKEY/ACCESS_KEY and SECRET_ACCESS_KEY/SECRET_KEY/SECRETKEY. |
| Azure | `{$AZURE.*}` / underscore settings: TENANT_ID/TENANTID, CLIENT_ID/CLIENTID, CLIENT_SECRET/CLIENTSECRET. |
| Redfish | `{$REDFISH.*}` / underscore USERNAME/USER and PASSWORD/PASS settings. New credentials keep certificate verification enabled. |
| VMware / JMX | Matching macro setting names are surfaced, but only existing WUG credentials can be selected: automatic property mapping is not verified. |

Names indicate **possible** purpose, not proof. Field pairing is conservative:
multiple distinct username/password macro names are not automatically paired.
SSH/Windows username suffixes are USER/USERNAME/USER_NAME/LOGIN; password
suffixes are PASSWORD/PASSWD/PASS. The matching must be a simple macro name
with a dot or underscore separator, not a context-macro expression.
Host text macros take precedence; identical inherited definitions may resolve;
conflicting inherited values remain unresolved. Global text macros are fallback
only. Secret/vault macros, masks, cycles, unresolved references and context
macros are never treated as recoverable secrets. No arbitrary macros are
expanded into commands.

**C** stages vault-backed creation; **R** refreshes the WUG credential list;
**Q** returns without selecting a credential. **U** provides manual WUG UI
instructions. Manual UI creation is an operator action outside the final wizard
write gate: only use it if deliberately desired. No credential values are printed.

Staged SecureStrings are disposed on apply/cancel/error. After **APPLY**,
`Save-DiscoveryCredential` writes encrypted bundles before `Add-WUGCredential`.
Credential POSTs have automatic retries disabled to avoid blind duplicate
creation. Failed creation can leave a vault entry; no rollback is attempted.
Saved vault defaults are offered on subsequent creation attempts.

The existing discovery framework owns encryption and storage. Its usual
current-user DPAPI location is:

```text
%LOCALAPPDATA%\WhatsUpGoldPS\DiscoveryHelpers\Vault
```

It also attempts an opposite-scope scheduling mirror, commonly:

```text
%ProgramData%\WhatsUpGoldPS\Vault
```

Do not assume storage is exclusively current-user. Configured DPAPI/AES modes,
scopes and paths remain framework-managed. Check ACLs and scheduling identities.
Vault initialization may create framework directories/configuration during
review; credential bundles and WUG objects are not written until APPLY.

At **C**, the wizard also offers **an additional credential type not detected
in Zabbix**. Use this for a WUG-native replacement whose Windows/SSH/cloud login
is absent from source configuration. Select one type, supply masked required
fields, and approve its purpose/assignment. VMware/JMX remain existing-only.

## 5. Monitor coverage

**"Unsupported" here means not automatically translated by this wizard,
not necessarily unavailable in WUG.** The current choices are:

| Outcome | Meaning / next step |
|---|---|
| Ready generated candidate | A supported limited conversion, such as an untransformed numeric SNMP collector or portable trap listener. Review it before APPLY; X can exclude it. |
| Review candidate | An explicit alternative requiring Y in M. Its polling/check semantics are not a faithful copy of Zabbix. |
| Existing WUG replacement | Select a previously configured monitor in M and approve its interval. The wizard assigns it; it does not translate or rewrite the source check. |
| Deferred / NeedsInput / Unsupported / Invalid | No approved automatic mapping. Inspect Reasons; skip or configure a reviewed WUG replacement. |
| Disabled / Skipped | Excluded from generated imports; Disabled is not offered for replacement in M. |

| Source | Behavior |
|---|---|
| Effective numeric SNMP items | Raw numeric performance collectors at fixed whole-minute intervals from 1 to 1440 minutes, preserving the complete numeric OID and resolved composite index. String/inventory values, rate/delta and preprocessing are not converted. |
| Resolved LLD instances | Concrete effective-host snapshot collectors. LLD rescan/lost-resource lifecycle remains a blocked requirement. |
| Simple SNMP current-value trigger | Supported comparisons become reviewable current-value active alternatives with explicit 60-second WUG cadence approval. History/recovery/dependencies remain blocked. |
| Portable SNMP trap filters | Passive event listeners; configure source trap routing independently. Historical alert behavior is not reproduced. |
| `icmpping` / `icmpping[]` | Reviewable WUG-native Ping with 5-second timeout, 1 retry and 32-byte payload, not equivalent Zabbix packet/trigger semantics. Explicit target/packet options, ping loss and latency checks are not automatically mapped. |
| `net.tcp.service[tcp,,PORT]` | Reviewable WUG-native TCP connection check to the selected device, with 5-second timeout and literal port 1-65535. Other service protocols/targets, service-performance keys and UDP checks remain blocked. |
| Simple HTTP GET | Reviewable HTTP/HTTPS connectivity alternative only for anonymous, non-redirect requests with peer/host verification settings enabled and no body/headers/proxy/query/fragment/URL credentials or unresolved URL macros. Uses a 10-second WUG timeout; source response/status/content/timing semantics are not translated. |
| Other HTTP / multistep web | Visible blocked requirements; choose an existing reviewed WUG monitor rather than flatten authentication/cookies/steps. |
| SSH / SQL checks | Visible requirements; select an existing reviewed WUG SSH/SQL monitor. No imported commands execute during discovery. |
| Agent CPU/memory/disk/services | Select reviewed existing WUG-native replacements. No automatic agent-to-WMI units/threshold equivalence. |
| Unsupported schedules/macros/transforms | Dependent items, preprocessing, rate/delta, custom schedules and unresolved monitor macros are deferred without guessing, rounding or raw-value fallback. Active item alternatives require a fixed 10-86400-second interval. |

### Not automatically migrated

- SSH command execution/output tests; SQL queries, ODBC DSNs and row conditions.
  Creating SSH/ADO credentials does **not** create these monitors.
- Zabbix agent CPU/memory/disk/service checks, custom agent keys, scripts,
  external checks, calculated items, and any item type/key outside the mappings
  above. Reviewed existing WUG monitors may be used instead.
- Authenticated HTTP, custom headers/bodies, proxies, redirects, query
  parameters and multistep web scenarios. REST credentials alone do not
  translate these requests or their response conditions.
- Historical trigger windows, recovery expressions, dependencies, cross-host
  comparisons and other expressions outside supported local current-value SNMP
  comparisons. Passive trap creation does not migrate historical alerts.
- Dynamic LLD rescanning, resource creation/removal and lost-resource lifecycle.
  The planner reads resolved items but does not import discovery rules as
  ongoing discovery. Offline table-trigger conversion is a separate feature.
- Zabbix history, dashboards, alert actions and general configuration outside
  the planner's inventory. Creating a host in WUG does not migrate its groups
  or all its Zabbix properties.
- DNS/IPv6 device targets, hosts without a primary interface, and SNMP checks
  on interfaces incompatible with the selected IPv4 target.

**Credential creation limits are separate:** VMware/JMX and source SSH key or
non-Basic HTTP authentication candidates are existing-credential-only.
Automatic SNMPv3 creation supports authPriv with MD5/SHA1 and DES/AES128, not
all Zabbix security levels/protocols. Masked/vault secrets cannot be recovered.
Selecting an existing credential is operator approval, not proof that WUG can
reproduce the source authentication mode.

The connected WUG server must advertise each generated monitor class. The
[offline conversion reference](../../docs/zabbix-template-conversion.md)
describes the separate export converter, including its table-trigger support.
The planner does not silently extend that converter's default SNMP allowlist.

## 6. Save and resume

At the review menu, press **S** and enter a **new** writable JSON path:

```text
New plan JSON path: C:\Migration\switch-selection.json
```

Resume with:

```powershell
& 'C:\Tools\WhatsUpGoldPS\examples\Import-ZabbixHostsToWUG.ps1' `
    -PlanPath 'C:\Migration\switch-selection.json'
```

The saved file contains API/server URLs, host IDs, configuration fingerprints,
selected definition IDs and reviewed existing-monitor references/intervals.
It excludes tokens, passwords, source exports, commands, credential bundles
and monitor payloads. Keep it private nonetheless: infrastructure IDs/URLs are
operational metadata. Existing files are never silently overwritten.

Resume re-authenticates, re-reads selected hosts and compares the generated
candidate/target snapshot. Changes to those candidates or selected WUG replacement
configurations stop application. The saved WUG server URL is also checked
after reconnection. Blocked source details are not executable saved
payloads; they are rediscovered. Credential selections/secrets and explicit
assignment approvals are collected again. If fingerprints changed, run without
`-PlanPath` and review a new plan.

## 7. Reruns, failures and live verification

To persist the returned receipts, run the wizard and export its pipeline output:

```powershell
& 'C:\Tools\WhatsUpGoldPS\examples\Import-ZabbixHostsToWUG.ps1' |
    Export-Csv 'C:\Migration\assignment-receipts.csv' -NoTypeInformation -Encoding UTF8
```

Choose a new report destination; `Export-Csv` follows normal PowerShell file
overwrite semantics. Interactive tables go to the host, not into these receipts.

- Existing exact device matches are reused; ambiguous matches or different
  addresses stop application. No try-create-all/catch-duplicate workflow.
- Library name/configuration conflicts are checked before wizard writes.
  Existing identical templates are reused; changed templates are not overwritten.
- New device IDs come from `idMap.resultId`; assignments are read back.
- Existing assignments, credentials not explicitly selected, device address and
  SNMP port are not rewritten. Verify an existing device's SNMP port and polling
  settings match the source.
- Writes are not transactional. If any call/read-back fails, inspect WUG and the
  vault before retrying. Already-created objects remain.
- Start with one host. Verify credentials, live monitor results, expected up/down
  conditions, units, TLS and network access in WUG. Confirm passive trap routing.
- Do not equate `AssignedMonitors` with healthy or live-tested monitors.

| Symptom | Action |
|---|---|
| No groups/hosts | Check token scope, permissions and enabled host status. |
| API permission error | Enable the exact failed read method; denied inventory is not ignored. |
| DNS/IPv6/interface mismatch | Configure/review a compatible literal IPv4 WUG target; blocked interfaces are not guessed. |
| Unsupported SNMPv3 mode | Select a supported existing credential or configure one intentionally; no weaker default. |
| HTTP candidate deferred | Review auth/TLS/method/redirect/response requirements in an existing WUG monitor. |
| No approved monitors | Use M to review alternatives or choose an existing replacement; empty devices are not created. |
| Missing SNMP binding | Use C and explicitly approve the SNMP device assignment before A. |
| Name/fingerprint conflict | Resolve WUG/source drift or review a fresh plan; no overwrite/retry shortcut. |
| Vault/signature/TLS error | Correct permissions, publisher trust or certificates; do not suppress validation. |

## 8. Original SNMP example and tests

The original exact-technical-host-name/template-export workflow remains available:

```powershell
& 'C:\Tools\WhatsUpGoldPS\examples\Import-ZabbixHostsToWUG.ps1' -Legacy
```

That path requires `configuration.export`, creates a temporary raw export,
uses IMPORT/CREATE confirmations, and leaves optional SSH/Windows credentials
library-only. It does not use the new planner's effective-host inventory or
saved selections.

Repository validation (no live Zabbix/WUG systems required):

```powershell
powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGZabbixMigrationPlannerTest.ps1
powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGZabbixHostImportTest.ps1
powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGZabbixConversionTest.ps1
```
