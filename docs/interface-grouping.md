# Interface grouping POC / MVP

For copy/paste operator recipes, setup, complete runnable-script parameter tables
and troubleshooting, start with the [helper folder README](../helpers/interfaces/README.md).

The standalone [entry script](../helpers/interfaces/Invoke-InterfaceGrouping.ps1)
builds a dashboard pack using the existing dynamic dashboard framework:

- A dark landing page with one card per group (GroupA through GroupL by default).
- Per-group searchable/exportable interface tables, status cards and utilization thresholds.
- Interface selector, RX/TX history chart, and expandable UTC poll samples.
- `groups.json` preserves the inventory, assignment IDs and historical samples.
- Optional, additive WUG device groups for navigation, with pre-checks and `-WhatIf`.
- Machine-wide default output under `%ProgramData%\WhatsUpGoldPS\Output\InterfaceGroups`.
- Versioned credential-free JSON profiles, CSV or interactive grouping review,
  pinned assignments/exclusions, and an explicit Token/Exact/Substring matching flag.
- Offline graphical browser review with searchable/bulk-editable decisions and
  downloadable CSV; preview never advances the baseline or writes WUG state.
- SNMP-assigned device eligibility before reports/probes, shared device metadata,
  single-collection wizard approval and cached offline demo replay.
- Ordered saved phrase rules with Contains/StartsWith/EndsWith/Token/Exact,
  selected description fields, first-match/overlap and visible unmatched ports.
- Recoverable local generation with ProgramData staging, destination locking and
  managed-file rollback; schema2 context-aware baselines retain last-known SNMP
  metadata through outages while keeping current observations explicit.
- Stable name-hashed group URLs, per-group and unique-scope freshness/collector
  summaries, Traffic/Utilization charts with UTC hover values and top consumers.
- Signed profile runner with transcripts, structured success/failure results and
  bounded log rotation; owned scheduled refresh tasks with explicit S4U/Interactive
  identity and exclusive output locking.
- Opt-in `-PublishToWug` copies only current HTML pages to an owned NmConsole pack,
  deploying static-file authorization before copying. Actual IIS authentication
  must be verified separately; see the [publishing guide](../helpers/interfaces/README.md#publish-into-the-wug-web-console-run-on-the-wug-server).

## Connect and run

```powershell
. .\functions\Connect-WUGServer.ps1
Connect-WUGServer -AutoConnect

$report = .\helpers\interfaces\Invoke-InterfaceGrouping.ps1 `
    -DeviceId 101,102 -OutputDirectory C:\Reports\InterfaceGroups
Start-Process $report.IndexPath
```

The entry and example scripts reuse the current PowerShell session's connection.
If disconnected, they call `Connect-WUGServer -AutoConnect` using the saved vault.
If no usable saved connection exists, they terminate without prompting; run
`Connect-WUGServer` interactively once to save one. A connection made by an assistant
or another PowerShell process does not connect your terminal. Auto-connect uses the
existing connection helper's vault/SSL behavior. Helpers explicitly load their
dependencies; no module import or auto-loading is required. PowerShell 5.1 is supported.

Group names use **literal case-insensitive Token matching** by default in both
entry scripts against WUG interface assignment comments or traffic descriptions.
Use `-MatchMode Substring` for the original broad matching or `-MatchMode Exact`
for whole-field matching; none of the modes interpret labels as regular expressions.
For example, `Customer GroupA uplink` matches `GroupA`. An interface can match more
than one group. Blank descriptions do not match; empty groups remain visible.
Custom names are accepted with `-GroupName GroupA,GroupB` or `-GroupName eno50,vmbr0`.
The latter is useful for a lab without GroupA aliases.

Reports default to the last four hours. Use `-Range lastPolled` for a small smoke
test, or `-Range lastNDays -RangeN 3` for history.

## Runnable examples: all interfaces and automatic groups

The [example script](../helpers/interfaces/Example-InterfaceGrouping.ps1) is in the
same helper folder. Run from the repository root; an existing session or saved vault
connection is reused automatically:

```powershell
# Every API-visible interface on one device, including unmatched descriptions.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -Mode AllInterfaces
Start-Process $report.IndexPath

# Every API-visible interface across all accessible WUG devices.
# This can take time; lastPolled is the example's default report window.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode AllInterfaces

# Collect interfaces for existing WUG groups, including their child groups.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -GroupId 41,70 -ReturnHierarchy -Mode AllInterfaces

# Match GroupA through GroupL across all accessible devices, previewing WUG writes.
.\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode NamedGroups -CreateWugGroups -WhatIf

# Discover Group-prefixed labels from descriptions and automatically create
# dashboards + WUG navigation groups. Only use this after checking your inventory.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode AutoGroups -CreateWugGroups

# Working lab example: use existing descriptions instead of GroupA labels.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -GroupName eno50,vmbr0 -CreateWugGroups
```

`AllInterfaces` creates one **All Interfaces** dashboard; it does not assign a group
to every port. It includes all interfaces represented by WUG interface active
assignments or traffic reports by default. Add `-UseSnmp -IncludeSnmpOnly` with
explicit discovery-vault names/versions to include SNMP-only ports as Unmonitored.

`AutoGroups` discovers labels such as `GroupA`, `GroupB`, `Group12`, and
`Group-Operations` from API comments/descriptions (case-insensitive, with token
boundaries). Group membership uses MatchMode (Token by default); only the explicit
Substring mode lets `GroupA` match `GroupAB`. It cannot infer arbitrary customer
names or fetch raw aliases. If no labels exist, it terminates with guidance instead
of guessing. Use `NamedGroups -GroupName CustomerOne,CustomerTwo` for other naming
conventions. Interfaces without a matching label are excluded from named/auto groups;
use `AllInterfaces` to see them.

No WUG changes occur unless `-CreateWugGroups` is supplied. The example uses separate
default output directories and owned WUG folders for each mode. `-WhatIf` suppresses
both WUG writes and local reports; omit it to apply. Returned objects contain
`IndexPath`, `Groups`, `NavigationGroups`, and `Inventory` for further inspection.

## Intelligent grouping from all collected descriptions

Use `IntelligentGroups` when your descriptions do not contain `GroupA` labels:

```powershell
# Collect all devices/interfaces, then infer shared leading prefixes/phrases.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode IntelligentGroups -Strategy Prefix
Start-Process $report.IndexPath

# Within existing WUG source groups, infer any repeated meaningful word.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -GroupId 41,70 -ReturnHierarchy -Mode IntelligentGroups -Strategy Words

# Preview automatically creating navigation groups for inferred categories.
.\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode IntelligentGroups -Strategy Prefix -CreateWugGroups -WhatIf
```

Both strategies populate the **entire selected inventory before grouping**, remove
IP addresses, numbers, basic port identifiers (GigabitEthernet, TenGigabitEthernet,
eth/eno/veth, VLANs, loopbacks, etc.), and ignore generic infrastructure words.
They require **at least two distinct inventory rows** per inferred group; the same
label appearing in an interface's comment and report name counts only once.

- **Prefix:** considers the first one to three meaningful words, preferring longer
  shared phrases. Each interface is assigned once; a group is created only if at
  least two still-unassigned interfaces match. For example, `event-wireless-02`
  and `event-wireless-03` become `event wireless`, while `azf-finance` and
  `azf-marketing` share `azf`. Membership uses inferred tokens, not substring search.
- **Words:** groups by any repeated meaningful word, so `azf-finance` can appear in
  both `azf` and `finance` if each word occurs on two or more interfaces.
- **Other Interfaces:** always present. Holds generic port names, unique descriptions,
  and interfaces without a reliable repeated label. No interface is discarded.

Each inferred card/page and `groups.json` explain the matching basis. Names are
normalized to lowercase, with punctuation separators converted to words. This is
a deterministic, conservative local heuristic, not semantic AI: it does not know
your organization or guarantee that shared words imply ownership. The MVP tokenizer
recognizes ASCII letters/digits; non-ASCII-only labels remain in Other Interfaces.
Review inferred groups before supplying `-CreateWugGroups`. Prefix and Words use
different default output folders and WUG navigation folders to avoid mixing modes.

Choose exactly one scope: `-DeviceId`, `-GroupId`, or `-AllDevices`. Source groups
default to direct members; `-ReturnHierarchy` includes child groups. Overlapping
groups/devices are deduplicated. Source IDs select inventory; they are not the output
navigation folder. All-device collection can take several minutes.

`-WhatIf` still authenticates and performs read-only collection; it suppresses WUG
group/membership and dashboard writes, not the existing connection helper's
authentication/vault behavior.

## WUG configuration (opt-in)

```powershell
# Read/query only; suppresses WUG and local file writes.
.\helpers\interfaces\Invoke-InterfaceGrouping.ps1 -DeviceId 101,102 `
    -CreateWugGroups -WhatIf

# Create a dedicated folder and its group children, then add matched devices.
.\helpers\interfaces\Invoke-InterfaceGrouping.ps1 -DeviceId 101,102 `
    -CreateWugGroups -ParentGroupId 0 -FolderName 'Interface Grouping POC' `
    -OutputDirectory C:\Reports\InterfaceGroups
```

Existing folders/groups must be static and have the helper's exact ownership
description. A conflicting name fails instead of modifying an unrelated group.
Re-runs pre-check child names and device membership; only missing members are added.
Membership is verified after writes. No devices or monitors are created, removed,
renamed, reassigned, or disabled. Stale device membership is **not removed**; the
regenerated dashboard always uses the current matching inventory.

**WUG groups contain whole devices, not selected interface monitors.** These groups
are navigation aids, not a per-interface permissions boundary. The exported pages
show only matched interfaces, but anyone with access to the entire pack can open
the other pages or JSON. Publish separate group folders with appropriate file/web
permissions if groups require isolation. Protect exports as operational data.

## API evidence and limits

The 2026 Swagger spec and lab confirm:

| Data | Endpoint / fields |
| --- | --- |
| Active status + description | `/devices/{id}/monitors/-?type=all&view=status`, built-in Interface class, `active.argument`, `active.comment`, `status`, `enabled` |
| Interface performance | `/devices/{id}/reports/interface-traffic`, `interfaceName`, `interfaceId`, `rxSpeedAvg`, `txSpeedAvg`, utilization, UTC poll time and `series` |
| Device navigation | `/device-groups/{id}/children`, `/child` (POST), `/devices/-` |

Monitor and report pagination is handled. API failures terminate instead of
generating a success-shaped partial report.

The join is **device ID + SNMP ifIndex**: the active assignment's numeric argument
matches the trailing `(ifIndex)` in the traffic description. The report's WUG
`interfaceId` is a different ID; it is never treated as ifIndex. Unknown formats
emit a warning and retain performance rows with Unknown status rather than guessing.
Only the built-in Interface active monitor class is interpreted as an ifIndex
monitor; arbitrary numeric arguments from custom monitors are excluded.

Raw `ifAlias`, `ifName` and `ifDescr` are **not exposed as separate fields** in these
documented REST responses. This MVP uses the descriptions WUG has stored, which may
reflect those values depending on its discovery settings. It does not claim to
read current raw SNMP aliases through REST. `/devices/{id}/interfaces/-` lists IP/hostname
polling interfaces, not SNMP ports; the L2 template export is opaque.

Optional `InterfaceGroupSnmpHelpers.ps1` reuses bundled SharpSnmp and selected
discovery-vault credentials to read IF-MIB ifDescr, ifName and ifAlias directly.
V1 uses Walk, V2/V3 BulkWalk; V3 preserves context/authentication/privacy. Only
selected credentials are attempted in order, stopping at the first nonempty
ifDescr table. Extra column failures are partial coverage, not reasons to probe
more credentials. Metadata joins by device ID + ifIndex and never overwrites
stored WUG descriptions/status/history. SNMP-only ports are explicitly Unmonitored.
Warn policy keeps flagged WUG rows on failure; Stop aborts incomplete enrichment.

`Start-InterfaceGroupingSetup.ps1` guides profile creation/reuse, source selection,
optional SNMP/vault setup, CSV-only preview, optional CSV/interactive decisions,
explicit run approval and opt-in scheduling. See the
[operator guide](../helpers/interfaces/README.md) for commands and all parameters.

Local exports compare a full-inventory snapshot (including unmatched/excluded
rows) with the previous successful local export and write changes JSON/CSV plus
an index summary. Failed/partial/disabled SNMP coverage makes apparent changes
uncertain, including SNMP-only disappearance from an otherwise empty device.
Preview does not advance the baseline. This is not a publication/authentication
success checkpoint; local snapshots and CSV/JSON are not copied into IIS.

The built-in Interface Utilization performance assignment is **device-wide**.
Its ID is shown for traceability, not claimed as an individual interface assignment.
Each port's traffic report ID and samples supply the performance detail.
No active monitor means Unknown, disabled means Disabled, and missing traffic
stays missing (never converted to zero). Existing traffic may remain available
after a performance collector is disabled; the dashboard shows both independently.
Status is a current snapshot; traffic is the chosen historical window. Poll time
and age are displayed so stale data is visible. Export again to refresh.

The per-group inventory table uses the standard framework with bundled dependencies
inlined by `InterfaceDashboardAssets.ps1`; interface packs do not depend on runtime
CDN access. Vendor license notices are embedded. The landing page and custom
traffic drill-down require no external chart library.
There is no embedded authentication token or browser API connection.

Publishing uses an exclusive destination lock, protected/hash-validated staging,
and a retained last-known-good recovery snapshot under machine ProgramData outside
the web console. Per-file promotion rolls back on failure; interrupted pending
transactions recover on the next publish. This is not a whole-pack atomic switch
or proof of power-loss durability.

The wizard supports named device browsing, profile editing/cloning and explicit
overlap/unmatched/matching-rule review. Readiness checks and operational status
are exposed by standalone commands in the helper folder. The runner retains
last-success/failure records independently of rotation. API retry settings reuse
the existing API wrapper (no nested retry loop); progress and optional file-signal
cancellation operate between collection steps. Landing cards show traffic consumers,
monitor coverage and uncertain changes without inventing missing rates.

## Lab POC

Validated against `192.168.74.74` using existing device `818`. Its inspected
comments use interface names rather than GroupA aliases, so the live pack matches
`eno50`, `vmbr0`, and `veth101i0`: two rows per group. The last group demonstrates
a Down assignment and a separate traffic-only interface with Unknown status.
The owned `Interface Grouping POC` folder and three children are left in WUG for
inspection. A second run reused the same group IDs and added zero members.
No existing monitor assignments or descriptions were changed.

```powershell
$lab = .\helpers\interfaces\Invoke-InterfaceGrouping.ps1 -DeviceId 818 `
    -GroupName eno50,vmbr0,veth101i0 -Range lastNHours -RangeN 4 `
    -CreateWugGroups -OutputDirectory C:\Reports\InterfaceGroupsLab
```

GroupA through GroupL matching is covered by offline fixtures. A synthetic demo
can therefore illustrate twelve groups without misrepresenting the lab's metadata.

## Validation

```powershell
powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGInterfaceGroupingTest.ps1
powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGInterfaceOperationsTest.ps1
powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGDashboardPublishingReliabilityTest.ps1
powershell.exe -NoProfile -File .\helpers\test\Invoke-WUGInterfaceDashboardAssetsTest.ps1
```

Operations regression includes a 2,000-interface/16-group export with exact
membership/page counts, under 90 seconds and 50 MiB fixture limits. Browser checks
block network access to exercise offline tables, charts and export actions.
Live IIS/SNMP/scheduled identity and power-loss scenarios remain separate.

Offline tests exercise 12-group matching, cross-device joins, disabled/unknown
states, missing traffic, literal matching, pagination, safe HTML and idempotent
navigation creation. Live lab validation uses existing monitors/history without
changing interface comments or aliases.
