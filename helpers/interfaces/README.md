# Interface grouping: operator guide

Build interface status and performance dashboards from WhatsUp Gold (WUG), with
optional WUG device groups for navigation. Start with the copy/paste recipes below.
You do not need to edit a script or import the module.

## Before you start

- Use Windows PowerShell **5.1 or newer** on Windows.
- Keep this folder inside the repository: the scripts load dependencies from
  [functions](../../functions) and [reports](../reports).
- Have a WUG API account that can read the devices, monitor assignments and reports
  you want to inspect. Creating navigation groups also requires WUG write permissions.
- Without SNMP, interfaces must already be represented by WUG active assignments
  or traffic reports. Opt-in SNMP can include additional ports as **Unmonitored**;
  it does not create WUG monitors or invent status/performance.
- Choose a writable, dedicated report folder. Reports contain operational data.
- Default packs use `%ProgramData%\WhatsUpGoldPS\Output\InterfaceGroups`, not a
  user's Documents or temporary directory. The account running the helper needs
  write permission there; it fails explicitly rather than falling back elsewhere.
- Use the existing signed scripts; follow your organization's script execution policy.

**Important:** WUG device groups contain **whole devices**, not individual ports.
The HTML dashboards filter individual interfaces. Neither automatic grouping nor
WUG navigation groups provide per-interface access control.

## Guided setup: closest to clickops

From the repository root, after configuring your WUG connection using section 2:

```powershell
.\helpers\interfaces\Start-InterfaceGroupingSetup.ps1
```

The wizard uses the existing session or saved WUG connection. No saved connection?
Follow section 2 first; the API collector never guesses a server or password.

1. Choose **N** for a new named JSON profile, or **E** to select a saved one.
   Saved profiles offer **R** (run unchanged), **M** (edit through menus), or
   **C** (clone). Clones use separate output/publication/navigation names and
   intentionally do not copy pinned review CSV references.
2. Choose selected device IDs, existing source group IDs (optional descendants), or
   all accessible devices. Option **4** browses device names, addresses and IDs
   through the API before selection. Start with device **818** for the lab.
3. Choose NamedGroups, AllInterfaces, AutoGroups, or IntelligentGroups.
   NamedGroups accepts your own comma-separated labels; blank keeps GroupA-GroupL.
4. Choose matching and traffic window, then an optional SNMP source. For SNMP,
   enter only the discovery-vault names you approve, followed by matching
   `V1,V2,V3` versions in the same order. You can list metadata-only vault entries
   and create/confirm the selected entries using the existing vault prompts.
   **V1/V2** needs a Single community value or a Bundle with `Community`;
   **V3** needs a Bundle with `Username`, `AuthProtocol` and `PrivacyProtocol`.
   A V3-shaped entry selected as V2 is rejected before probing. At the existing
   credential prompt, **Y** uses it, **R** resets it, and **N** skips it and
   cancels setup (the skipped entry will not remain selected).
5. Decide whether the approved run should create WUG navigation groups or publish
   to the local WUG web directory. Both default **No**.
   Choosing publishing prompts for an existing `NmConsole` directory (blank
   autodetects standard installation paths). A remote API connection does not
   enable remote filesystem publishing. On a workstation without WUG, choose
   **No** and generate local dashboards; enable publishing on the WUG host later.
   If a saved profile still has publishing enabled and readiness fails, the wizard
   offers **1=Disable publishing in this profile** or **2=Set the existing WUG
   NmConsole directory**. The chosen correction is saved with ShouldProcess
   approval and readiness is checked again; **Q** cancels without applying it.
   Disabling publishing does not disable SNMP or requested WUG navigation groups.
6. The wizard runs readiness checks, then produces a **CSV-only preview first**.
   It lists device names, grouping rules, unmatched interfaces and overlap counts. Open
   the CSV, review interactively, or continue without edits. CSV edits require
   `Apply=True`; changing only `Groups` does not activate a decision.
7. Approve the full run explicitly. Declining leaves the saved profile and preview,
   but no dashboard/WUG/publishing writes. Edited decisions apply to that run even
   if you decline saving them for future runs.
8. Optionally register refresh scheduling after a successful run. S4U and
   Interactive logon modes are explicit choices; verify vault/network access under
   the actual task identity.

Enter **Q** at any setup prompt to stop subsequent actions. Previously approved
profile, vault or CSV writes are not undone. Interactive per-interface review uses
its existing `YES` confirmation instead. `-WhatIf` exits without any prompts or
writes. `-Confirm` requests confirmation at write/run boundaries.

| Wizard parameter | Purpose |
| --- | --- |
| `ProfileDirectory` | Existing/new JSON profile folder; default `%ProgramData%\WhatsUpGoldPS\InterfaceGroups\Profiles`. |
| `SkipSchedule` | Suppresses the optional scheduled-refresh prompt. |

New profiles get separate output subfolders under
`%ProgramData%\WhatsUpGoldPS\Output\InterfaceGroups\<profile-name>`. Reusing a profile
keeps its settings; a missing output directory is saved as a profile-specific
ProgramData folder. Use a different profile/output folder for independent scopes.

## Optional SNMP: current ifAlias, ifName and ifDescr

This uses the repository's existing [SharpSnmp helpers](../snmp/WhatsUpGoldPS.Snmp)
and [discovery vault](../discovery/DiscoveryHelpers.ps1). It is read-only on devices.
It does **not** decrypt the entire vault, export WUG library secrets, try every
saved credential, or fall back to a guessed community.

To create credentials through existing secure prompts, without putting passwords
in scripts or profiles:

```powershell
. .\helpers\discovery\DiscoveryHelpers.ps1
# V1 and V2 both use the vault's SNMPv2 community credential shape.
$null = Resolve-DiscoveryCredential -Name 'Interfaces.GenericCommunity' -CredType SNMPv2
$null = Resolve-DiscoveryCredential -Name 'Interfaces.GenericV3' -CredType SNMPv3
```

Use only the entries you intend to try. Their order is priority order, attempted
against each selected device's validated WUG `networkAddress` IP. The first
successful nonempty **ifDescr** read wins; ifName/ifAlias are then read with that
same credential. An alias-column failure does not trigger more credential probes.

```powershell
# One device first: alias-based auto groups plus clearly unmonitored extra ports.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -Mode AutoGroups -UseSnmp `
    -SnmpCredentialNames 'Interfaces.GenericCommunity','Interfaces.GenericV3' `
    -SnmpCredentialVersions V2,V3 -IncludeSnmpOnly
Start-Process $report.IndexPath

# Inspect ALL ports across ALL devices before assigning categories.
$preview = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode AllInterfaces -UseSnmp `
    -SnmpCredentialNames 'Interfaces.GenericV3' -SnmpCredentialVersions V3 `
    -IncludeSnmpOnly -PreviewOnly
Start-Process $preview.PreviewPath
```

For legacy devices, specify **V1** explicitly. SNMPv3 uses the vault username,
context, authentication/privacy protocols and passwords, including authNoPriv.
Profiles store **names and versions only**, not these secrets. NamedGroups,
AutoGroups and IntelligentGroups consider raw SNMP fields alongside original WUG
comments/descriptions; the WUG fields are not overwritten.

| Parameter (both collection entry scripts / profile Settings) | Default | Purpose |
| --- | --- | --- |
| `UseSnmp` | Off | Load bundled SNMP transport and enrich selected device inventory. Requires the two aligned credential lists. |
| `SnmpCredentialNames` | None | Ordered 1-12 selected discovery-vault names. No duplicate name/version pairs. |
| `SnmpCredentialVersions` | None | One `V1`, `V2`, or `V3` per selected name, in identical order. |
| `IncludeSnmpOnly` | Off; wizard offers Yes | Include unmatched SNMP ports with source `SNMP-only`, status `Unmonitored`, no rates/history. Requires UseSnmp. |
| `SnmpFailureAction` | `Warn` | `Warn`: keep WUG descriptions and flag failed/partial enrichment. `Stop`: fail the run on any failed/partial device enrichment. |
| `SnmpPort` | `161` | UDP port, 1-65535. |
| `SnmpTimeout` | `3000` | Timeout in milliseconds, 500-60000; per underlying SNMP operation, not a whole-run deadline. |

`SnmpStatus` is Complete, Partial, Failed, or NotFound (no matching ifIndex for a
WUG row). Empty alias values are valid. Missing columns or incomplete per-port
metadata warn and show Partial. Dashboards expose raw values, source and coverage;
SNMP-only ports never appear Up merely because SNMP answered.

Each successful device needs three column walks; failed candidates add attempts.
V1 uses Walk, V2/V3 BulkWalk; V3 also performs engine discovery. Large all-device
runs can be slow and generate authentication logs. Start small and use the minimum
approved credential set. Live V1/V2/V3 device verification is still required in
your environment.

## Quick demo and set-and-forget refresh

**You do not need to edit every interface.** The automatic groups are already the
proposal. In the wizard, choose **3=Continue without edits** and approve the run.
In browser review, **Accept automatic groups** clears manual overrides (confirming
if you have edits). Download CSV only if you want to pin different memberships.
An empty bulk assignment is now rejected without erasing rows. **Reset selected
to automatic** restores selected rows to their original proposals. The initial
review shows groups and counts so you can see **what was collected** immediately.

### Efficient live collection

For SNMP-enabled wizard profiles, missing `DeviceFilter` is set to
`SnmpAssigned` with save approval. Profile edit menu **6=Device eligibility**
lets you explicitly choose `SnmpAssigned` or `All`. Existing direct scripts
default to `All` for backwards compatibility; opt in:

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -DeviceFilter SnmpAssigned -Mode IntelligentGroups -Strategy Words
Start-Process $report.IndexPath
```

The helper must enumerate candidates and make **one lightweight assigned-credential
query per candidate** (`type=snmp`, `view=id`); the API does not provide that
filter on the source device list. Only eligible devices get monitor/report reads
and optional SNMP probes. Empty/failing credential queries are not silently
treated as success. Basic device metadata is reused for SNMP target resolution,
avoiding a second device read. Counts report eligible/skipped devices.

Assigned **WUG** SNMP credentials determine eligibility, not which vault secret is
used. Optional SNMP still uses only your selected discovery-vault credentials;
an eligible device is not guaranteed reachable with those credentials.
`DeviceFilter=SnmpAssigned` also works without `UseSnmp` for WUG-only dashboards.

Wizard preview, console review and full approval now reuse **one collection**.
Approval exports the observations you reviewed, not a newly queried inventory.
This does not make WUG navigation writes or publishing atomic, and collection
timestamps/freshness remain unchanged.

### Repeat a demo without contacting devices

Each live example/profile run saves
`OutputDirectory\collected-inventory.json`, including raw inventory and history.
This is a local operational-data file, not a published artifact or successful-run
baseline. Restrict folder access. For your saved `all` profile:

```powershell
$profile = "$env:ProgramData\WhatsUpGoldPS\InterfaceGroups\Profiles\all.json"
$observations = "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\all\collected-inventory.json"

# One live refresh after configuring the profile:
$report = .\helpers\interfaces\Invoke-InterfaceGroupProfile.ps1 -ProfilePath $profile
Start-Process $report.IndexPath

# Fast repeat: no connection, vault decryption, API reads or SNMP probes.
$demo = .\helpers\interfaces\Invoke-InterfaceGroupProfile.ps1 `
    -ProfilePath $profile -InventoryPath $observations
Start-Process $demo.IndexPath
```

Offline demos go to a separate `Offline-<mode>` ProgramData output folder and do
not replace the live pack or last successful live-run status. They cannot create
WUG groups or publish. They are **saved observations**, not current status: warnings,
timestamps and freshness make that explicit. Report ranges cannot be expanded
offline; the saved collection's range is used. Refresh live to get new samples.

**An older dashboard does not necessarily have a collection cache.** If replay
reports that collected-inventory.json is missing, bootstrap it once without
dashboard generation, publishing or WUG navigation writes:

```powershell
$capture = .\helpers\interfaces\Invoke-InterfaceGroupProfile.ps1 `
    -ProfilePath $profile -PreviewOnly
$demo = .\helpers\interfaces\Invoke-InterfaceGroupProfile.ps1 `
    -ProfilePath $profile -InventoryPath $capture.InventoryPath
if ($demo.IndexPath) { Start-Process $demo.IndexPath }
```

The capture is a live API/optional-SNMP collection. Replay remains offline and
fails explicitly on a missing cache; it does not silently rescan or fabricate
observations from group pages. Do not call Start-Process after a failed run.

### Saved phrase rules: beginning, end or anywhere

Wizard grouping option **5=Saved phrase rules** (or saved-profile edit **2**, then
**5**) asks for each group name, matching phrase, position and field. Choose
`FirstMatch` for mutually exclusive groups or `Overlap` for all matching rules.
Rules persist in the profile and automatically classify new interfaces at each
refresh; unmatched interfaces remain in **Other Interfaces**.

```powershell
$rules = @(
    @{ Name='Tunnels'; Value='tunnel to'; Match='Contains'; Field='Any' }
    @{ Name='WAN'; Value='WAN-'; Match='StartsWith'; Field='IfAlias' }
    @{ Name='Backups'; Value='-backup'; Match='EndsWith'; Field='IfAlias' }
)

# Iterate on saved observations without rescanning:
$demo = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -InventoryPath $observations -Mode Rules -Rules $rules -RuleMode FirstMatch
Start-Process $demo.IndexPath

# Save a rules-based live profile (no credentials/secrets in JSON):
. .\helpers\interfaces\InterfaceGroupingHelpers.ps1
$null = Save-InterfaceGroupProfile -Path $profile -Settings @{
    AllDevices=$true; DeviceFilter='SnmpAssigned'; Mode='Rules'
    Rules=$rules; RuleMode='FirstMatch'
    OutputDirectory="$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\all"
}
```

The last command intentionally replaces the selected profile's settings; use a
new profile path if you want to preserve the original. Add your selected `UseSnmp`
and aligned credential references through wizard edit **5** if you need fresh
raw SNMP metadata. Without SNMP, rules operate on stored WUG descriptions.

| Rule property | Meaning |
|---|---|
| `Name` | Destination group; no semicolons/newlines; Other Interfaces is reserved. Multiple rules may target the same group without duplicate membership. |
| `Value` | Literal phrase, not regex/wildcard. `tunnel to` can match anywhere using Contains. |
| `Match` | Contains (anywhere), StartsWith/EndsWith (trimmed field boundaries), Token (whole token/phrase boundaries), Exact (whole trimmed field). All case-insensitive. |
| `Field` | Any (default), IfAlias, IfName, IfDescr, InterfaceComment or InterfaceName. Raw aliases are usually best for suffix rules; WUG comments can contain address/suffix text. |
| `RuleMode` | FirstMatch respects saved rule order; Overlap assigns all matching group names. |

For automatic scheduled refreshes, invoke the saved profile directly; no wizard
or CSV edits are required. Existing scheduler setup remains available:

```powershell
.\helpers\interfaces\Register-InterfaceGroupScheduledTask.ps1 `
    -Register -ProfilePath $profile -TaskName 'InterfaceGroups-All' `
    -TriggerType Hourly -RepeatIntervalMinutes 60
```

Use the scheduler's documented identity/credential options below as needed.
Scheduling is opt-in; verify device access under its actual identity.

## Grouping-change reports

Local generation is recoverable: a complete pack is built and validated under
`%ProgramData%\WhatsUpGoldPS\InterfaceGroups\LocalExport`, then promoted with an
exclusive destination lock and rollback journal. A failure restores the previous
managed pack; interrupted/failed recovery is retried before the next export.
Review CSV/HTML and unrelated files are preserved. Promotion is **per-file**, not
an atomic directory replacement; do not serve the local working directory as an
unprotected website. Recovery data contains inventory metadata: restrict access
to ProgramData/output folders and keep recovery data outside IIS.

Every successful **local dashboard export** updates:

- `inventory-snapshot.json`: the full selected inventory and final memberships,
  including unmatched/excluded interfaces, plus per-device SNMP coverage.
- `changes.json` and `changes.csv`: added/removed interfaces, changed WUG/raw SNMP
  descriptions, and changed group memberships since the previous local export.
- The landing page's **Grouping changes** table.

The first run establishes a baseline. PreviewOnly/WhatIf never replace it. A
different WUG server starts a new baseline with a warning. Corrupt baseline JSON
fails explicitly; inspect it rather than silently losing comparison history.

```powershell
Import-Csv (Join-Path (Split-Path $report.IndexPath -Parent) 'changes.csv') |
    Format-Table DeviceName,InterfaceKey,Change,UncertainSnmpCoverage -AutoSize
```

When SNMP fails, is partial, or is no longer collected for a previously enriched
device, apparent changes are marked **UncertainSnmpCoverage=True**. A disappeared
SNMP-only row is not a confirmed physical port removal. Missing SNMP fields also
warn when validating pins; existing explicit decisions are retained, but actual
changed descriptions/aliases require re-review. Keep PreviewPath different from
the applied ReviewPath.

The baseline describes local export, **not successful publishing or verified IIS
authentication**. Raw snapshots/change CSV/JSON remain local; the publisher copies
only its HTML manifest. The index contains change summaries, so protect it like
the group pages. Changing the selected scope/mode naturally changes memberships;
use separate output folders when those comparisons would be misleading.

Snapshots now use **SchemaVersion 2**. `Interfaces` means observations from this
run; `LastKnownInterfaces` retains available raw metadata/memberships through
SNMP outages without inserting those values into dashboards as current readings.
Recovered observations compare against retained metadata, avoiding false alias
changes or additions solely due to an outage. Missing SNMP-only rows can remain
uncertain across repeated outages; complete collection confirms removal.

`CollectionContext` and its fingerprint describe explicit source scope, matching,
grouping, report range, ordered selected SNMP candidates, and applied review
decisions (not their filename). Configuration changes produce
`Change=ConfigurationChanged` and `Classification=ConfigurationChange`; related
membership changes are not claims of physical inventory changes. Other records
are `InventoryChange` or `UncertainObservation`. SchemaVersion 1 snapshots upgrade
on the next successful export; their unknown configuration is not guessed.

## Graphical local review

The guided setup offers **4=Graphical browser review** after collection. Edit
individual rows or select filtered rows for bulk grouping/exclusion. Download the
decisions CSV, then paste its full path back into the wizard. Optionally save it
as the profile's durable review file. Closing the page alone saves nothing.

Without the wizard:

```powershell
$preview = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode IntelligentGroups -Strategy Prefix -BrowserReview
Start-Process $preview.ReviewHtmlPath

# After editing and downloading decisions, apply them in a fresh collection:
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode IntelligentGroups -Strategy Prefix `
    -ReviewPath 'C:\Review\interface-group-decisions.csv'
Start-Process $report.IndexPath

# Same preview workflow from a saved profile; interactive overrides are not scheduled:
$preview = .\helpers\interfaces\Invoke-InterfaceGroupProfile.ps1 `
    -ProfilePath "$env:ProgramData\WhatsUpGoldPS\InterfaceGroups\Profiles\ports.json" `
    -BrowserReview
Start-Process $preview.ReviewHtmlPath
```

`-BrowserReview` implies PreviewOnly: it writes CSV plus HTML but no dashboards,
baseline, WUG navigation or publishing, even if those flags are supplied.
`-BrowserReviewPath` optionally selects an `.html` filename and requires
BrowserReview. Default: `OutputDirectory\interface-review.html`. It cannot target
managed dashboard names (`index.html`/`group-*.html`) or overwrite unrelated HTML.
Actual filesystem reparse points are rejected; choose an ordinary local folder
rather than a OneDrive cloud-placeholder/junction path.

The offline page uses no server, CDN, API tokens or credentials. Interface identity
and source metadata are read-only; `Apply=False` keeps automatic grouping,
`Apply=True` pins semicolon-separated groups, and `Exclude=True` excludes an
applied row. Applied rows require groups or exclusion. Errors block CSV download.
The existing importer revalidates identities and available metadata on the next
run; a downloaded CSV is not proof that live metadata is unchanged. Keep this
operational-data page and CSV local with restricted folder permissions.

## Readiness checks before collection

```powershell
$profile = "$env:ProgramData\WhatsUpGoldPS\InterfaceGroups\Profiles\ports.json"

# Local settings/files/vault metadata checks only: no decryption or API/SNMP calls.
$ready = .\helpers\interfaces\Test-InterfaceGroupReadiness.ps1 -ProfilePath $profile
$ready.Checks | Format-Table Check,Status,Detail -Wrap -AutoSize

# Explicitly opt in to a temporary write probe and limited WUG API check.
$ready = .\helpers\interfaces\Test-InterfaceGroupReadiness.ps1 `
    -ProfilePath $profile -TestWriteAccess -CheckApi
```

| Parameter | Purpose |
| --- | --- |
| `ProfilePath` | Required saved profile, validated using the same rules as the runner. |
| `CheckApi` | Connect/reuse saved WUG session, resolve scope and read the first device. Does not collect monitors/history or probe SNMP. |
| `TestWriteAccess` | Create and remove one uniquely named probe in an existing output/publication directory or nearest existing ancestor. Honors WhatIf/Confirm. |

Checks are **Passed**, **Failed** or **Unverified**. `ReadyToAttempt=True` means
there are no detected failures, not that every permission or E2E path is proven.
`FullyVerified` remains False. The check inspects selected vault metadata/expiry
without decrypting secrets. Review CSV fields/flags, cancellation signals,
publishing ownership and parent Forms configuration are also checked.

A write probe in an ancestor cannot prove that a not-yet-created target will
inherit suitable permissions; that result remains Unverified. API preflight does
not establish monitor/report permissions across every device. WhatIf suppresses
write/API probes. WUG/IIS authentication, SNMP credentials and scheduled identity
still need their own live verification.

## One-command operational status

```powershell
$status = .\helpers\interfaces\Get-InterfaceGroupStatus.ps1 `
    -ProfilePath $profile -IncludeScheduledTasks
$status | Format-List ProfilePath,LogDirectory,ExportAgeMinutes,DashboardExists,DashboardAgeMinutes
$status.Health | Format-List
$status.SnmpCoverage
$status.LatestFailure
$status.Publication
$status.ScheduledTasks | Format-Table -AutoSize
```

| Parameter | Purpose |
| --- | --- |
| `ProfilePath` | Required profile whose run records are read. |
| `LogDirectory` | Optional override when the runner/task uses a custom log directory. |
| `IncludeScheduledTasks` | Query owned tasks linked to this exact profile; include state, logon type, last/next run and LastTaskResult. Omit to avoid Task Scheduler access. |

The runner retains `last-success.json` and `last-failure.json` independently of
rotated per-run records. Preview runs do not replace the last successful
dashboard-run record. Status distinguishes the latest run, last completed
successful dashboard run, latest retained failure, and actual dashboard file
existence/age. A failure does not erase the previous success. Publication success
means files were copied/verified, **not** that Forms authentication was tested.
Malformed records fail explicitly rather than displaying healthy-looking defaults.

## Recoverable, serialized publishing

Publishing now stages and hash-validates the complete HTML pack before touching
published pages. A destination-scoped exclusive lock prevents concurrent
publication into the same canonical destination, even from different profiles or
output folders. Existing ownership, reparse-point checks and protection-first
installation remain in place.

The last-known-good snapshot and recovery journal are stored outside the web
console in `%ProgramData%\WhatsUpGoldPS\DashboardPublishing\<destination-hash>`.
The publisher restricts this storage and verifies backups. It restores the prior
snapshot on a promotion failure; an interrupted pending transaction is recovered
before the next publish. Restore failures are explicit, not hidden.

**This is recoverable publication, not a whole-directory atomic IIS switch.**
Files are promoted individually, so readers can briefly see mixed generations.
After abrupt process termination, recovery waits for the next publishing attempt.
Power-loss durability and live IIS behavior require separate environment verification.
Do not manually delete a pending recovery journal to make an error disappear.
Staging/backups contain only HTML/configuration, not raw group/change JSON.

## Offline dashboards and richer landing cards

Interface group pages inline the repository's existing licensed dashboard
JavaScript/CSS/fonts. There are no runtime CDN fetches or additional web asset
files to copy: the HTML-only publishing manifest remains sufficient. Vendor
license notices remain embedded. Missing or unapproved runtime dependencies cause
an explicit export error. Device URLs in report data are not treated as asset
dependencies.

Landing cards show active-monitored versus no-active-monitor counts, SNMP-only
ports, Down status, freshness, top five RX+TX consumers and relevant grouping-change
uncertainty. Traffic summaries use only complete valid snapshots; missing values
never become zero. Totals may combine different poll times and are labelled
accordingly. Historical/stale data remains clearly labelled, not silently current.

## Collection progress, bounded retries and cancellation

WUG and SNMP collection show per-device progress, and WUG checks cancellation
between monitor pages. Both entry scripts and profile Settings accept:

| Parameter | Default | Purpose |
| --- | --- | --- |
| `ApiMaxRetries` | `3`, valid 0-10 | Use the existing WUG API wrapper's exponential-backoff retries for transient HTTP/network failures. Set 0 to disable transient retries; existing authentication-refresh behavior remains separate. No additional nested retry loop. |
| `CancellationPath` | None | Optional operator-controlled signal file. Presence cancels between reads and before review/dashboard/WUG/publishing writes. Relative profile paths resolve beside the profile. |

```powershell
$signal = "$env:ProgramData\WhatsUpGoldPS\InterfaceGroups\cancel-ports.signal"
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -Mode AllInterfaces -ApiMaxRetries 2 -CancellationPath $signal

# From another console, request cancellation:
New-Item -ItemType File -Path $signal
# Before the next run, explicitly remove that exact signal:
Remove-Item -LiteralPath $signal
```

Ctrl+C remains available for interactive runs. Cancellation does not interrupt a
currently blocking HTTP/SNMP operation, undo already completed WUG navigation
writes, or replace a publication rollback. SNMP never probes additional credentials
after the first successful ifDescr read; selected-entry fallback is separate from
WUG transient retries.

Inline vendor assets increase per-page size. Export runtime and pack size depend
on interface counts, group counts and history windows. Prefer smaller scopes and
shorter history windows when packs grow.

## 1. Open PowerShell in the repository

In VS Code, open the repository and choose **Terminal > New Terminal**. Check that
the prompt is at the repository root, not inside this helper folder.

For this workspace, you can paste:

```powershell
Set-Location 'T:\OneDrive\GitHub\WhatsUpGoldPS'
```

For another installation, change that path to your checkout. All recipes below
assume the repository root is your current directory.

Use the complete blocks as shown. In PowerShell, a backtick at the end of a line
continues the command; **do not put spaces after the backtick**. A one-line version
of the quick start is also provided.

## 2. Set up the connection once

Both runnable scripts automatically reuse an existing connection in **your current
PowerShell session**, or use the saved WUG vault connection if you are disconnected.
If you already saved a connection, skip this step.

First-time setup:

```powershell
. .\functions\Connect-WUGServer.ps1
Connect-WUGServer
```

Follow the connection prompts. Successful connections are saved by the existing
connection helper for later use. Do not paste passwords into commands.

To deliberately connect to a specific server:

```powershell
. .\functions\Connect-WUGServer.ps1
$credential = Get-Credential
Connect-WUGServer -serverUri 'wug.example.com' -Credential $credential
```

Replace `wug.example.com` with your server. For the lab, that server is
`192.168.74.74`. The default API connection is HTTPS on port 9644; connection
parameters belong to `Connect-WUGServer`, not to the interface scripts.

A missing/unusable saved connection causes an explicit error rather than an
interactive prompt inside the report script. Run the first-time setup to fix it.
Auto-connect inherits the existing connection helper's vault and SSL behavior;
review its certificate-validation warnings. A connection made in another terminal,
process does not connect your terminal.

## 3. Quick start: inspect one device, without changing WUG

Device `818` is the validated lab example. Replace it with your own WUG **device ID**
(not an IP address).

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -Mode AllInterfaces `
    -OutputDirectory "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\OneDevice"
Start-Process $report.IndexPath
```

One-line version:

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 -DeviceId 818 -Mode AllInterfaces; Start-Process $report.IndexPath
```

This writes an **All Interfaces** dashboard and opens it in your default browser.
It does not create WUG groups or change monitors.

## Choose what to collect

Use exactly **one** scope option in a command:

| Scope | Copy/paste argument | Meaning |
| --- | --- | --- |
| One device | `-DeviceId 818` | All API-visible interfaces on this device. |
| Several devices | `-DeviceId 818,814` | Collect both; repeated device IDs are queried once. |
| Existing WUG device groups | `-GroupId 41,70` | Direct device members of the selected groups. |
| Groups and their descendants | `-GroupId 41,70 -ReturnHierarchy` | Also include devices in child groups; overlapping membership is deduplicated. |
| Entire accessible inventory | `-AllDevices` | Every device accessible to your connected WUG account. Can take several minutes. |

These are **source** groups. They select devices to read, not the destination for
new navigation groups. Group IDs and device IDs are different identifiers.

### Find device and group IDs

If you already know your IDs, skip this block. Otherwise, load the read helpers
and use the saved connection:

```powershell
. .\helpers\interfaces\InterfaceGroupingHelpers.ps1
Connect-InterfaceGroupServer

Get-WUGDevice -View basic -Limit 250 |
    Select-Object id, displayName, hostName |
    Format-Table -AutoSize

Get-WUGDeviceGroup -View detail |
    Select-Object Id, Name, ParentGroupId |
    Format-Table -AutoSize
```

## Choose how interfaces are grouped

| Mode | When to use it | Membership / unmatched interfaces |
| --- | --- | --- |
| `AllInterfaces` | Inspect everything before deciding on labels. | One big dashboard, including interfaces with blank or uncommon descriptions. |
| `NamedGroups` | You know the desired labels: GroupA, CustomerOne, etc. | Case-insensitive literal Token matches by default; interfaces can match several groups. Unmatched interfaces are excluded; empty requested groups stay visible. |
| `AutoGroups` | Descriptions already contain Group-prefixed labels. | Detects labels such as GroupA, Group12 or Group-Operations, then uses MatchMode like NamedGroups. No labels means an error with guidance. |
| `IntelligentGroups` + `Prefix` | Infer categories from common naming prefixes or leading phrases. | Collects everything first, then assigns each interface once. Unmatched interfaces go to **Other Interfaces**. |
| `IntelligentGroups` + `Words` | Explore common meaningful words across different prefixes. | Collects everything first; an interface can belong to several word groups. Unmatched interfaces go to **Other Interfaces**. |

If you omit `-Mode`, the default is **NamedGroups**, searching for **GroupA through
GroupL**. Use an explicit mode in operator commands to avoid surprises.

### How intelligent grouping works

Both strategies use WUG's stored interface comments and traffic descriptions:

1. Collect the entire chosen inventory.
2. Normalize descriptions to lowercase and tokenize punctuation-separated words.
3. Remove IP addresses, basic port identifiers (GigabitEthernet, TenGigabitEthernet,
   eth/eno/veth, VLANs, loopbacks, etc.), numbers, and generic infrastructure words.
4. Require at least **two interface rows** per inferred category. A label repeated
   in one interface's comment and report name still counts as one interface.
5. Keep unmatched rows in **Other Interfaces**, including unique descriptions and
   ports with only basic names.

**Prefix** considers the first one to three meaningful words, preferring longer
shared phrases. `event-wireless-02` and `event-wireless-03` can form `event wireless`;
`azf-finance` and `azf-marketing` can share `azf`. A longer phrase can take members
away from a broader prefix; groups need two remaining rows to be emitted.

**Words** considers any repeated meaningful word. `azf-finance` can be in both `azf`
and `finance` when each occurs on at least two interfaces. Consequently, adding up
group counts may exceed the inventory count.

The card/page and exported JSON explain each inferred match. This is deterministic
local inference, **not semantic AI** or an ownership guarantee. No descriptions are
sent to an external AI service. The current tokenizer recognizes ASCII words;
non-ASCII-only labels remain in Other Interfaces. Review results before creating
WUG groups.

## Copy/paste recipes

Replace device/group IDs with IDs from your environment. The output folder names
below keep different experiments separate.

### A. All interfaces across all accessible devices

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode AllInterfaces `
    -OutputDirectory "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\AllInterfaces"
Start-Process $report.IndexPath
```

### B. All interfaces within existing groups and child groups

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -GroupId 41,70 -ReturnHierarchy -Mode AllInterfaces `
    -OutputDirectory "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\SourceGroups"
Start-Process $report.IndexPath
```

Omit `-ReturnHierarchy` for direct members only.

### C. Infer common prefixes across all devices

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode IntelligentGroups -Strategy Prefix `
    -OutputDirectory "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\InferredPrefixes"
Start-Process $report.IndexPath
```

### D. Infer repeated words within selected source groups

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -GroupId 41,70 -ReturnHierarchy `
    -Mode IntelligentGroups -Strategy Words `
    -OutputDirectory "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\InferredWords"
Start-Process $report.IndexPath
```

### E. Match labels you specify

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode NamedGroups -GroupName 'GroupA','GroupB','GroupC' `
    -OutputDirectory "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\NamedGroups"
Start-Process $report.IndexPath
```

You can substitute labels such as `'CustomerOne','CustomerTwo'`. Both entry scripts
now default to **Token** matching: `GroupA` matches `customer GroupA uplink`, not
`GroupAB` or `_GroupA`. Hyphens, slashes, spaces and punctuation are boundaries;
`eno50` still matches `eno50.75`. Labels are always literal, never regex/wildcards.

Use `-MatchMode Exact` for an entire trimmed comment or traffic description, or
`-MatchMode Substring` to restore the original MVP behavior (`GroupA` matches GroupAB).
Exact compares the complete stored field, including any report `(ifIndex)` suffix
and combined assignment comments; it does not fetch a raw ifAlias field.

Lab example using descriptions already present on device 818:

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -Mode NamedGroups -GroupName 'eno50','vmbr0','veth101i0'
Start-Process $report.IndexPath
```

### F. Automatically detect Group-prefixed labels

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode AutoGroups `
    -OutputDirectory "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\AutoLabels"
Start-Process $report.IndexPath
```

Use this only when descriptions have Group-prefixed labels. It does not infer
categories such as academy or wireless: use IntelligentGroups for those.

### G. Include historical performance samples

The example defaults to `lastPolled`, which is a quick snapshot. For charts with
historical points, select a larger window:

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -Mode AllInterfaces -Range lastNHours -RangeN 4 `
    -OutputDirectory "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\FourHours"
Start-Process $report.IndexPath
```

For three days, use `-Range lastNDays -RangeN 3`. Larger scopes and windows take
longer and produce larger HTML/JSON files.

### H. Preview automatic WUG group creation

Use the same configuration for review, preview and apply:

```powershell
$options = @{
    AllDevices      = $true
    Mode            = 'IntelligentGroups'
    Strategy        = 'Prefix'
    FolderName      = 'Interface Categories - Prefix'
    OutputDirectory = "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\PrefixCategories"
    Range           = 'lastPolled'
}

# Review real dashboards first. No grouping changes are made in WUG.
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 @options
Start-Process $report.IndexPath

# Preview WUG writes. Does not write a new dashboard pack.
$preview = .\helpers\interfaces\Example-InterfaceGrouping.ps1 @options `
    -CreateWugGroups -WhatIf
$preview.Groups | Select-Object Name, InterfaceCount | Format-Table -AutoSize
```

`-WhatIf` still connects and reads the inventory. It suppresses navigation-group,
membership and local report writes, **not** authentication or the connection
helper's normal vault behavior. If the destination folder does not exist yet,
the preview reports that creation and skips child/member writes; it does not
simulate IDs for groups that have not been created. `IndexPath` is null in a
preview, so do not call `Start-Process $preview.IndexPath`.

### I. Apply WUG navigation-group creation

Run this only after reviewing recipe H. Keep `$options` in the same terminal:

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 @options `
    -CreateWugGroups

$report.NavigationGroups |
    Select-Object Name, FolderId, GroupId, AddedDevices |
    Format-Table -AutoSize
Start-Process $report.IndexPath
```

This creates an owned folder under WUG's root, creates child navigation groups,
and adds the devices with matching interfaces. For IntelligentGroups, this also
includes the **Other Interfaces** group. Requested empty groups may be created.

Re-runs reuse existing owned groups and add only missing device members. They do
**not** remove stale members or old child groups. An unowned/conflicting folder
name causes an error rather than modifying someone else's group. Use a different
`-FolderName` or investigate ownership. Never remove ownership descriptions just
to bypass this safeguard.

### J. Put named navigation groups under a specific WUG parent

The simpler [Invoke-InterfaceGrouping.ps1](Invoke-InterfaceGrouping.ps1) supports
`-ParentGroupId`. It accepts explicit devices and named groups only:

```powershell
$options = @{
    DeviceId        = @(818)
    GroupName       = @('eno50', 'vmbr0')
    ParentGroupId   = 130
    FolderName      = 'Named Interface Categories'
    OutputDirectory = "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\NamedUnderParent"
    Range           = 'lastNHours'
    RangeN          = 4
}

.\helpers\interfaces\Invoke-InterfaceGrouping.ps1 @options -CreateWugGroups -WhatIf

# After review, run without WhatIf:
# $report = .\helpers\interfaces\Invoke-InterfaceGrouping.ps1 @options -CreateWugGroups
# Start-Process $report.IndexPath
```

Replace `130` with an existing destination parent group ID. There is no
`-ParentGroupId` on the example script; its output navigation folder is under root.

## Publish into the WUG web console (run on the WUG server)

Publishing is separate from `-CreateWugGroups`: one writes HTML to IIS; the other
creates navigation groups in the WUG API. You can use either, both, or neither.
API connectivity to a remote WUG server does **not** give filesystem publishing
access. Run on the actual WUG server, from an elevated terminal or an account with
the necessary directory write permissions. Do not generate directly into the IIS
directory: generate under ProgramData, then use the protected publisher.

### Generate and publish in one command

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode IntelligentGroups -Strategy Prefix `
    -PublishToWug -PackName 'interfaces-prefix'

$report.Publication | Format-List
```

The publisher auto-detects the local installation in the standard Program Files
locations. For a custom WUG installation:

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -Mode AllInterfaces `
    -PublishToWug -NmConsolePath 'D:\WUG\Html\NmConsole' `
    -PackName 'interfaces-all'
```

The simpler entry script also supports these three publishing parameters.
`PackName` is a URL-safe directory name, **not** the WUG API navigation FolderName.
Keep separate PackName values for different scopes or categories.

### Publish an existing generated pack, without querying the API again

```powershell
. .\helpers\reports\DashboardPublishingHelpers.ps1
$source = "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\IntelligentGroups-Prefix"

# Preview filesystem writes only.
Copy-WUGDashboardPack -SourcePath $source -PackName 'interfaces-prefix' -WhatIf

# Apply after reviewing.
$published = Copy-WUGDashboardPack -SourcePath $source -PackName 'interfaces-prefix'
$published | Format-List
```

`Copy-WUGDashboardPack` is the shared copy function. Its parameters are:

| Parameter | Purpose |
| --- | --- |
| `SourcePath` | Required generated directory with index.html, group HTML and groups.json. JSON determines the current page list but is **not copied**. |
| `NmConsolePath` | Existing WUG Html\NmConsole directory; auto-detected locally if omitted. No guessed fallback directory is created. |
| `PackName` | Required single folder name, 1-80 characters: start with a letter/digit, then letters/digits/underscores/hyphens. No path traversal or nested paths. |
| `WhatIf` / `Confirm` | Standard ShouldProcess options covering the entire protection/copy operation. |

The destination is `<NmConsole>\dashboards\<PackName>`. The publisher:

1. Requires the NmConsole parent web.config to declare Forms authentication.
2. Refuses unowned existing pack directories and reparse-point destinations/files.
3. Deploys and verifies the pack web.config **before any HTML copy**.
4. Places the anonymous-deny rule before the authenticated allow rule, enables managed
   modules for static files, disables directory browsing, and blocks JSON requests.
5. Copies only the current manifest-listed group pages and index.html, checking SHA-256
   hashes. Raw groups.json and unrelated source files are not published.
6. Removes obsolete helper-generated group HTML pages **only within this owned pack**,
   including the original numbered pages during migration to stable links.
   It does not touch other dashboards or the parent NmConsole web.config.

Protection/copy failures terminate; there is no SkipWebConfig switch. Existing
discovery scripts use the extracted shared web.config deployment function too;
configuration write failures now terminate rather than merely warning.
The older [discovery copy script](../discovery/Copy-WUGDashboardReports.ps1) still
has its own single-file workflow; use Copy-WUGDashboardPack for these multipage packs.

If the parent inherits Forms settings rather than declaring them locally, the
publisher stops for administrator review. Locked IIS sections or custom IIS module
configuration can still cause HTTP errors after deployment. **A successful file
copy is not proof of working authentication.**

### Verify the actual IIS site end-to-end

Use the web console address, **not** the REST API URL/port. Normally a published
URL looks like:

```text
https://wug.example.com/NmConsole/dashboards/interfaces-prefix/index.html
```

Perform these checks on the actual WUG server/site before declaring E2E success:

1. In a fresh private/incognito browser with no WUG cookies, open index.html and
   at least one group page. They must redirect to WUG login or reject access,
   never show dashboard data anonymously.
2. Log in normally to the WUG console in a regular browser. Open the published
   index and click every group. Confirm tables, interface selectors, charts and
   back navigation work; HTTP 500/500.19 is **not** a successful access restriction.
3. Try `<published-folder>/groups.json`: it must not expose raw inventory.
4. Re-run publishing, then repeat the checks.

Automated anonymous checks for **every** generated HTML page:

```powershell
. .\helpers\reports\DashboardPublishingHelpers.ps1
$source = "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\IntelligentGroups-Prefix"
$consoleUrl = 'https://wug.example.com/NmConsole'

Test-WUGDashboardPackAccess -SourcePath $source `
    -ConsoleUri $consoleUrl -PackName 'interfaces-prefix'
```

Replace the URL with your actual HTTPS console root. The checker rejects HTTP 200
for anonymous requests, IIS failures, and unrelated redirects. Without WebSession,
it reports `AuthenticatedAccessVerified = False` and warns: finish the authenticated
browser check above. It does not turn API bearer tokens into WUG Forms cookies.

If your existing approved web-login automation already supplies an authenticated
PowerShell WebRequestSession, verify authenticated HTML content too:

```powershell
# $wugWebSession must already be authenticated to WUG Forms in this process.
# Do not paste cookies/passwords into scripts or save them alongside reports.
Test-WUGDashboardPackAccess -SourcePath $source `
    -ConsoleUri $consoleUrl -PackName 'interfaces-prefix' `
    -WebSession $wugWebSession
```

The checker compares the authenticated response to each generated HTML file.
It does not log in, persist cookies or ignore TLS failures. Its parameters are
SourcePath, ConsoleUri, PackName, and optional WebSession.

`Publication.AuthenticationVerified` remains False after copying, by design.
Use the separate access verification result/browser evidence to establish E2E
success. Copying files and generating configuration do not establish successful
IIS authentication; verify access on the WUG server.

## Review, rename, merge, exclude and pin interfaces

Choose either CSV editing or interactive review. Both work with all four modes.
Review is local: it does not rename aliases, modify assignments, or enforce access.

### CSV workflow (recommended for repeatable automation)

```powershell
$preview = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode IntelligentGroups -Strategy Prefix -PreviewOnly

$preview.Groups | Select-Object Name,InterfaceCount | Format-Table -AutoSize
Start-Process $preview.PreviewPath
```

Open the CSV in Excel or a text editor, save as UTF-8 CSV, and keep its headers:

| Column | Meaning |
| --- | --- |
| `InterfaceKey` | Device ID + ifIndex, or device + report IDs for unjoinable traffic. Do not edit it. |
| `DeviceName` | Display context only. |
| `InterfaceComment`, `InterfaceName` | Original descriptions. Applied rows must still match them on future runs; prevents silently pinning a reused ifIndex to the wrong customer. |
| `IfAlias`, `IfName`, `IfDescr` | Raw opt-in SNMP values. Applied rows require re-review when available metadata changes; unavailable fields warn instead of pretending validation succeeded. |
| `ProposedGroups` | Informational automatic memberships before overrides. |
| `Groups` | Desired group names separated by semicolons. Rename by replacing a label; merge by giving interfaces the same label; overlap by listing several names. Group names cannot contain semicolons in review workflows. |
| `Exclude` | True excludes this interface from every dashboard group, but not from selected-scope health/inventory. |
| `Apply` | Set True only for decisions to pin. False leaves automatic matching in charge on future runs. Both flags must be True/False, not Yes/No or 1/0. |
| `MatchExplanation` | Read-only grouping-rule explanation for proposed memberships; shows no-match explicitly. |

For example, set `Groups` to `Customer Operations`, `Apply=True` on two interfaces
to merge them into that group; use `Exclude=True, Apply=True` to exclude a row.
Originally populated groups emptied by review disappear from the HTML; explicitly
requested empty groups and Other Interfaces remain. Existing WUG navigation groups
are still additive and are not deleted.

Copy the edited CSV to a durable decisions path, then apply it:

```powershell
$decisions = "$env:ProgramData\WhatsUpGoldPS\InterfaceGroups\Profiles\prefix-review.csv"
New-Item -ItemType Directory -Path (Split-Path $decisions -Parent) -Force | Out-Null
Copy-Item -LiteralPath $preview.PreviewPath -Destination $decisions

$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -AllDevices -Mode IntelligentGroups -Strategy Prefix -ReviewPath $decisions
Start-Process $report.IndexPath
```

New interfaces still get inferred normally. Missing pinned interfaces warn rather
than creating synthetic rows. Changed descriptions terminate for re-review; generate
a fresh preview without ReviewPath, check that interface, and update its decision.
PreviewPath must differ from ReviewPath, so regeneration cannot overwrite pins.
`-PreviewOnly` suppresses dashboards, publishing and WUG groups even if enabled;
`-WhatIf` also suppresses the preview CSV.

### Interactive workflow

```powershell
$report = .\helpers\interfaces\Example-InterfaceGrouping.ps1 `
    -DeviceId 818 -Mode AllInterfaces -Review
Start-Process $report.IndexPath
```

For each interface, press Enter to keep the proposal, enter `-` to exclude it, or
enter one or several semicolon-separated group names. Type **YES** at the final
confirmation to proceed; any other answer terminates before report/WUG writes.
The decisions are saved to PreviewPath (default review-preview.csv) and can be
used later as ReviewPath. This can be lengthy for AllDevices; use CSV instead.
Do not use Review with WhatIf or in a NonInteractive scheduled process.

## Save settings once, run a profile

Profiles are versioned JSON configuration, not scripts or credential stores.
Run the included [example profile](Example-InterfaceGroupProfile.json) after changing
its device ID to one accessible to your account:

```powershell
$report = .\helpers\interfaces\Invoke-InterfaceGroupProfile.ps1 `
    -ProfilePath .\helpers\interfaces\Example-InterfaceGroupProfile.json
Start-Process $report.IndexPath
```

Create your own reusable all-device profile:

```powershell
. .\helpers\interfaces\InterfaceGroupingHelpers.ps1
$profile = "$env:ProgramData\WhatsUpGoldPS\InterfaceGroups\Profiles\prefix.json"
$settings = @{
    AllDevices        = $true
    Mode              = 'IntelligentGroups'
    Strategy          = 'Prefix'
    Range             = 'lastNHours'
    RangeN            = 4
    StaleAfterMinutes = 60
    OutputDirectory   = "$env:ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\PrefixProfile"
}
# Optional after completing the CSV workflow:
# $settings.ReviewPath = "$env:ProgramData\WhatsUpGoldPS\InterfaceGroups\Profiles\prefix-review.csv"
# Optional local WUG publishing:
# $settings.PublishToWug = $true
# $settings.PackName = 'interfaces-prefix'

Save-InterfaceGroupProfile -Path $profile -Settings $settings
$report = .\helpers\interfaces\Invoke-InterfaceGroupProfile.ps1 -ProfilePath $profile
Start-Process $report.IndexPath
```

Save validates settings before replacing an existing profile. Supported Settings
are the example entry's scope, mode, matching, WUG group, range, freshness, output,
publishing and ReviewPath parameters. Store switches as JSON true/false and IDs/
GroupName as arrays. Relative OutputDirectory, ReviewPath and NmConsolePath resolve
beside the profile. No environment-variable expansion or executable expressions are
evaluated. Unsupported settings (including passwords, tokens, Review and common
parameters) are rejected. Protect profile/CSV write permissions: they control scope
and opt-in WUG writes. Give each profile its own output directory and PackName.

| Profile command/parameter | Purpose |
| --- | --- |
| `Save-InterfaceGroupProfile -Path -Settings` | Save credential-free settings; supports WhatIf/Confirm. |
| `Invoke-InterfaceGroupProfile.ps1 -ProfilePath` | Required existing profile, using the normal entry point/vault. |
| `Invoke-InterfaceGroupProfile.ps1 -ReviewPath` | Decisions CSV override for this run only; does not alter saved Settings. |
| `PreviewOnly`, `Review`, `PreviewPath` | Per-run overrides; same behavior as the entry scripts. |
| `BrowserReview`, `BrowserReviewPath` | Per-run graphical preview overrides; same behavior as entries; never saved as scheduled profile settings. |
| `LogDirectory` | Default ProgramData\WhatsUpGoldPS\Output\InterfaceGroups\logs\profile-<path hash>. |
| `KeepLogs` | 1-1000; default 30 most recent transcript logs and 30 per-run JSON records. Only runner-owned filenames are rotated. |
| `WhatIf` / `Confirm` | Standard write controls; WhatIf also suppresses logs/state files. |

Each profile run writes a transcript, per-run JSON and `latest-result.json` with
Success, UTC start/end, report/published paths, health counts and any error.
Failures terminate, giving scheduled PowerShell a nonzero exit code. These logs
may contain operational metadata; secure the directory appropriately.

## Schedule automatic refresh

This regenerates API data **and** republishes when enabled in the profile; it is
not just an HTML copy task. Uses the workspace's signed PowerShell `-File` runner
and Task Scheduler folder `\WhatsUpGoldPS\`, without encoded commands or policy bypass.

```powershell
$profile = "$env:ProgramData\WhatsUpGoldPS\InterfaceGroups\Profiles\prefix.json"

# Preview registration.
.\helpers\interfaces\Register-InterfaceGroupScheduledTask.ps1 `
    -Register -ProfilePath $profile -TaskName 'InterfaceGroups-Prefix' -WhatIf

# Refresh every 30 minutes; start once under the configured task identity.
.\helpers\interfaces\Register-InterfaceGroupScheduledTask.ps1 `
    -Register -ProfilePath $profile -TaskName 'InterfaceGroups-Prefix' `
    -RepeatIntervalMinutes 30 -LogonType S4U -RunNow

Get-ScheduledTaskInfo -TaskName 'InterfaceGroups-Prefix' -TaskPath '\WhatsUpGoldPS\'
```

**S4U is unattended but is not proof of vault/network access.** It runs as the
current Windows user without saving a password. Network shares and CurrentUser
DPAPI vault access can fail. Keep scripts/profile/output on local disk; a checkout
on a mapped drive may not be available to the task. Inspect LastTaskResult and
latest-result.json after RunNow. For reliable logged-on user vault access, explicitly
use `-LogonType Interactive`; there is no silent fallback. For Program Files publishing,
use appropriate permissions or `-RunLevel Highest` from an approved elevated terminal.

Other recipes:

```powershell
# Daily at 03:15, only while logged on.
.\helpers\interfaces\Register-InterfaceGroupScheduledTask.ps1 `
    -Register -ProfilePath $profile -TaskName 'InterfaceGroups-Prefix' `
    -TriggerType Daily -TimeOfDay '03:15' -LogonType Interactive

.\helpers\interfaces\Register-InterfaceGroupScheduledTask.ps1 -Show

.\helpers\interfaces\Register-InterfaceGroupScheduledTask.ps1 `
    -Remove 'InterfaceGroups-Prefix' -WhatIf
# Repeat without WhatIf after review.
```

| Scheduler parameter | Default / purpose |
| --- | --- |
| `Register`, `Show`, `Remove` | Mutually exclusive actions; Remove is the task name. |
| `ProfilePath` | Required for Register; validated before any task change. |
| `TaskName` | InterfaceGroups-Refresh; must start InterfaceGroups- with letters/digits/_/-. Existing tasks need the helper ownership description. |
| `TaskFolder` | \WhatsUpGoldPS\; custom nested folder names supported with a trailing backslash. |
| `TriggerType` | Hourly, Daily, AtStartup; default Hourly. |
| `RepeatIntervalMinutes` | 5-1440, default 30; used for Hourly repetition. |
| `TimeOfDay` | Local HH:mm, default 00:00; used for Daily/Hourly start. |
| `LogonType` | S4U (default) or Interactive, current Windows user. |
| `RunLevel` | Limited (default) or Highest. |
| `LogDirectory` | Optional absolute local log path; otherwise the profile runner default. |
| `RunNow` | Start the scheduled task after registration, under its task identity; does not wait for completion. |
| `WhatIf` / `Confirm` | Preview/confirm registration or removal. |

Task Scheduler uses IgnoreNew for overlapping executions. Both entry scripts also
hold an exclusive output-directory lock during generation/publishing, protecting
manual versus scheduled runs sharing that directory. Different output directories
publishing to the same PackName are not serialized: use separate packs/profiles.
The empty `.interface-grouping.lock` file remains as a lock anchor; its existence
alone does not mean a run is active. The handle releases on success/failure/process exit.

## Freshness and performance views

Every group shows generation time, Down counts, stale/suspect timestamps and
missing/disabled collectors. The index counts unique interfaces for the **whole
selected scope**, including unmatched/excluded interfaces, rather than summing
overlapping categories. Returned `Health` gives the same counts for automation.

`Freshness` is Fresh, Stale, Missing, Invalid or Future; `LastSampleUtc` is the latest
valid report/history timestamp; `AgeMinutes` is null when unavailable. Freshness is
calculated at generation, not continuously polled. Old historical ranges may
intentionally be stale. Generation time and collector health are distinct from
whether the interface is currently Up.

Details offer Traffic/Utilization modes, decimal rate units, UTC hover/keyboard
values, missing-sample gaps and top-five snapshot consumers. Click a table row or
consumer entry to select its chart. Tables need the framework's CDN dependencies;
the selector, top consumers, charts and poll samples work without those dependencies.
Top consumers exclude incomplete/invalid snapshots and do not total overlapping
groups or invent bandwidth for missing data.

## Parameter reference: Example-InterfaceGrouping.ps1

This is the recommended script for most operators. All parameters are optional
except that you must choose one device scope.

| Parameter | Type / default | Purpose and behavior |
| --- | --- | --- |
| `DeviceId` | `int[]`; no default | Required for explicit-device scope. One or several positive WUG IDs. Mutually exclusive with GroupId and AllDevices. |
| `GroupId` | `int[]`; no default | Required for source-group scope. One or several existing WUG group IDs; root is 0, All Devices is -2. Other negative IDs are rejected. Reads their devices; does not set the destination for new groups. Mutually exclusive with DeviceId and AllDevices. |
| `AllDevices` | switch; off | Select all accessible WUG devices. Supply the switch, not `-AllDevices:$false`. Mutually exclusive with DeviceId and GroupId. |
| `ReturnHierarchy` | switch; off | Only available with GroupId. Include devices in child groups; otherwise direct members only. |
| `Mode` | string; `NamedGroups` | Choose NamedGroups, AllInterfaces, AutoGroups or IntelligentGroups. See the mode table above. |
| `Strategy` | string; `Prefix` | Prefix or Words. Only valid when Mode is IntelligentGroups; explicitly supplying it with another mode is an error. |
| `GroupName` | `string[]`; GroupA through GroupL | NamedGroups literal labels. Only valid when Mode is NamedGroups; explicitly supplying it with another mode is an error. Quote labels containing spaces. |
| `MatchMode` | string; `Token` | Token, Exact or Substring matching for NamedGroups/AutoGroups; does not affect inference. |
| `PreviewOnly` | switch; off | Write editable review CSV and return proposals; suppress dashboard generation, publishing and WUG group writes even if those switches are supplied. Still queries the API. |
| `PreviewPath` | string; optional | Write review CSV here even during a normal run; defaults to OutputDirectory\review-preview.csv for PreviewOnly/Review. Must differ from ReviewPath. |
| `BrowserReview` | switch; off | Export offline graphical review HTML and CSV only; implies PreviewOnly and suppresses baseline/dashboard/WUG/publishing writes. |
| `BrowserReviewPath` | string; optional | Local HTML output, default OutputDirectory\interface-review.html; requires BrowserReview and cannot overwrite managed dashboard/unrelated HTML. |
| `DeviceFilter` | All (direct-script default) or SnmpAssigned | Assigned-WUG-SNMP eligibility before monitor/report/SNMP reads; wizard SNMP profiles use SnmpAssigned. |
| `Rules`, `RuleMode` | Mode Rules; ordered objects; FirstMatch default | Saved named literal phrase rules, field selection, first-match or overlapping membership; unmatched goes to Other Interfaces. |
| `InventoryPath` | Example/profile runner per-run option | Offline replay of collected-inventory.json with separate output, saved timestamps/range and no WUG/publishing writes. Not saved in scheduled profile settings. |
| `InventoryExportPath` | Example per-run option | Live observation cache JSON destination, default OutputDirectory\collected-inventory.json. |
| `ReviewPath` | string; optional | Import edited CSV; only Apply=True rows pin membership or exclusions. Missing pinned interfaces warn; changed descriptions terminate for re-review. |
| `Review` | switch; off | Console review of every interface, followed by explicit YES confirmation; also writes decisions CSV. Not for NonInteractive tasks or WhatIf. |
| `StaleAfterMinutes` | integer; `60`, valid 1-525600 | Latest valid traffic timestamp older than this is stale. Exact threshold is fresh; missing timestamps remain missing; future timestamps over five minutes ahead are flagged. |
| `CreateWugGroups` | switch; off | Opt in to WUG folder/child creation and whole-device membership additions. Without it, only local reports are written. |
| `OutputDirectory` | string; derived ProgramData folder | Destination for HTML and JSON. Created if absent. Existing pack files are overwritten; unrelated/obsolete local files are not cleaned up. Choose a dedicated folder per scope/mode. |
| `FolderName` | string; derived name | Owned WUG destination folder name under root. Used only with CreateWugGroups. Not a source group, file path, or category label. |
| `PublishToWug` | switch; off | After a successful new export, copy the HTML pack into protected local NmConsole. Independent of CreateWugGroups. |
| `NmConsolePath` | string; auto-detected | Existing WUG Html\NmConsole directory. Explicitly supplying it requires PublishToWug. |
| `PackName` | string; `interfaces-<modeLabel>` | URL-safe published subfolder; explicit use requires PublishToWug. modeLabel includes strategy for IntelligentGroups. |
| `Range` | string; `lastPolled` | Traffic window: lastPolled, today, yesterday, lastWeek, lastNHours or lastNDays. Does not change current active monitor status or polling settings. |
| `RangeN` | integer; `4`, valid 1-365 | Number of hours/days for lastNHours/lastNDays. Not sent for other ranges, even though the report window label may display it. |

Default destinations:

| Mode | Output directory | WUG folder name |
| --- | --- | --- |
| NamedGroups | `<ProgramData>\WhatsUpGoldPS\Output\InterfaceGroups\NamedGroups` | `Interface Grouping Example - NamedGroups` |
| AllInterfaces | `<ProgramData>\WhatsUpGoldPS\Output\InterfaceGroups\AllInterfaces` | `Interface Grouping Example - AllInterfaces` |
| AutoGroups | `<ProgramData>\WhatsUpGoldPS\Output\InterfaceGroups\AutoGroups` | `Interface Grouping Example - AutoGroups` |
| IntelligentGroups / Prefix | `<ProgramData>\WhatsUpGoldPS\Output\InterfaceGroups\IntelligentGroups-Prefix` | `Interface Grouping Example - IntelligentGroups-Prefix` |
| IntelligentGroups / Words | `<ProgramData>\WhatsUpGoldPS\Output\InterfaceGroups\IntelligentGroups-Words` | `Interface Grouping Example - IntelligentGroups-Words` |

Different device scopes using the same mode share these defaults. Supply explicit
output and folder names to keep runs separate.

## Parameter reference: Invoke-InterfaceGrouping.ps1

Use this script for explicit device IDs, named groups, and a configurable destination
parent. It does **not** have Mode, Strategy, AllDevices, GroupId or ReturnHierarchy.

| Parameter | Type / default | Purpose and behavior |
| --- | --- | --- |
| `DeviceId` | `int[]`; required | Positive WUG device IDs to collect. Repeated IDs are queried once. |
| `GroupName` | `string[]`; GroupA through GroupL | Literal case-insensitive labels to match against comments/descriptions. Unmatched interfaces are excluded; requested empty groups remain. |
| `MatchMode` | string; `Token` | Token, Exact or legacy Substring. |
| `PreviewOnly`, `PreviewPath`, `ReviewPath`, `Review`, `StaleAfterMinutes` | Same defaults as example script | Same review and freshness behavior described in the preceding table. |
| `Range` | string; `lastNHours` | Same six accepted windows as the example; defaults to historical data rather than lastPolled. |
| `RangeN` | integer; `4`, valid 1-365 | Hours/days for a lastN window. Ignored in API requests for other ranges. |
| `OutputDirectory` | string; `<ProgramData>\WhatsUpGoldPS\Output\InterfaceGroups\NamedGroups` | Dedicated HTML/JSON destination. Existing pack files are overwritten. Shared default with the example's NamedGroups mode. |
| `CreateWugGroups` | switch; off | Opt in to owned WUG navigation folder/child creation and additive whole-device membership. |
| `ParentGroupId` | integer; `0`, valid 0-2147483647 | Existing destination parent. 0 is root. Not the source device scope. Used with CreateWugGroups. |
| `FolderName` | string; `Interface Grouping POC` | Owned destination folder created/reused beneath ParentGroupId. |
| `PublishToWug` | switch; off | Publish the newly exported HTML pack to protected NmConsole. |
| `NmConsolePath` | string; auto-detected | Existing WUG Html\NmConsole directory; explicit use requires PublishToWug. |
| `PackName` | string; `interfaces-named` | URL-safe publishing folder; explicit use requires PublishToWug. |

### Standard PowerShell options on both scripts

| Option | Use |
| --- | --- |
| `-WhatIf` | Collect/compute results but suppress grouping writes and local reports. See recipe H for limitations. |
| `-Confirm` | Request confirmation at ShouldProcess operations; not needed for ordinary report runs. Read prompts carefully because creation/member/file decisions are separate operations. |
| `-Confirm:$false` | Disable confirmation prompts. Does not enable WUG creation; CreateWugGroups is still required. |
| `-Verbose` | Show additional diagnostic messages from helpers/API functions. |
| `-ErrorAction Stop` | Treat non-terminating errors as terminating. These helpers already terminate on collection failures; useful in automation. |
| `-WarningAction` | Standard warning control. Prefer leaving warnings visible, especially for unjoinable interfaces or connection/SSL issues. |

Other standard advanced-script common parameters, such as Debug and output/error
variables, are available through PowerShell. There is no OpenDashboard parameter:
use `Start-Process $report.IndexPath` after a successful report write.

## Read the dashboard and returned results

1. Open `index.html` using `Start-Process $report.IndexPath`.
2. Click a category card to open its interface dashboard.
3. Use status/device cards, search, sortable columns and the table's export controls.
4. Choose an interface under **Interface performance details**, click its table row,
   or select a **Top 5 consumers** entry.
5. Switch between traffic and utilization charts; hover or keyboard-focus samples
   for UTC timestamps/values. Expand **Poll samples (UTC)** for individual values.
6. Use **back to index** to switch categories.

The pack contains:

- `index.html`: group navigation and counts.
- `group-<SHA256>.html`: per-group dashboards with stable links derived from the
  trimmed, case-normalized group name. Reordering/adding categories no longer changes
  another group's URL. Renaming a group intentionally creates a new URL. These are
  not WUG IDs. Older numbered packs remain publishable, but old numbered bookmarks
  are not retained after a new stable-link publication.
- `groups.json`: selected group inventory, matching basis where applicable,
  assignment/report identifiers, and historical samples.

Inspect results without the browser:

```powershell
$report.Groups | Select-Object Name, InterfaceCount | Format-Table -AutoSize

$report.Inventory |
    Select-Object DeviceId, DeviceName, IfIndex, InterfaceComment, InterfaceName,
        Status, TrafficAvailable |
    Format-Table -AutoSize

$report.NavigationGroups |
    Select-Object Name, FolderId, GroupId, AddedDevices |
    Format-Table -AutoSize

# Inspect one category's actual interfaces.
($report.Groups | Where-Object Name -eq 'Other Interfaces').Interfaces |
    Select-Object DeviceName, IfIndex, InterfaceComment, InterfaceName, Status |
    Format-Table -AutoSize
```

Both scripts return IndexPath, Groups, NavigationGroups, Inventory, Publication,
Health, Decisions and PreviewPath. Groups include PageName after export.
Publication is null unless publishing succeeds. Its PublishedPath, PublishedIndexPath
and RelativeUrl identify the copied pack; AuthenticationVerified is False until
actual web access is independently verified. The example
also returns Mode, Strategy (null outside IntelligentGroups), and DeviceCount.
NavigationGroups is empty when creation was not requested (or writes were skipped
before results could be produced).

### Interpret status and performance correctly

- **Up/Down/Maintenance:** current enabled active interface monitor status.
- **Disabled:** active assignments exist but none are enabled.
- **Unknown:** no usable active assignment/status, or the interface cannot safely
  be joined to the active monitor. Traffic can still be available.
- **TrafficAvailable:** report data exists in the chosen window, not proof of
  current polling or interface health.
- **PerformanceEnabled:** the device-wide Interface Utilization collector is
  enabled. Its ID is not a separate per-port performance assignment.
- Missing samples/values stay missing, not zero. Raw table/JSON RX/TX values are
  bits per second; chart/details use decimal bps/Kbps/Mbps/Gbps. Utilization uses
  the API's reported percentages.
- Active assignment status is current; traffic may be historical/stale. Review
  PollTimeUtc and SecondsSincePoll. Export again to refresh.

These pages are **snapshots**, not live API clients. No token is embedded in HTML.
The standard table uses CDN dependencies, so browser internet access is needed for
its interactive features. The landing page and custom chart need no external chart
library. These entry scripts do not expose an Offline parameter.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| "No saved WUG connection in vault" / connection failure | Run first-time connection setup in this terminal. Check server, API port, credentials and permissions. No credentials are guessed. |
| Command worked in another terminal but says disconnected here | Sessions are separate. Use the saved-vault auto-connect or explicitly connect in this terminal. |
| NamedGroups shows 12 empty groups | The defaults are GroupA-GroupL. Inspect AllInterfaces, supply your actual GroupName labels, or use IntelligentGroups. |
| AutoGroups reports no Group-prefixed labels | Your descriptions do not follow that convention. Use NamedGroups or IntelligentGroups. |
| Only Other Interfaces appears | There are no repeated meaningful matches after normalization, or the scope is too small. This is valid, not a fake success group. Inspect descriptions or try Words/a larger scope. |
| Too many word groups / counts exceed total interfaces | Words allows overlap. Use Prefix for a single assignment per interface. |
| Wrong/overbroad named matches | Use MatchMode Token (default) to distinguish GroupA from GroupAB, or Exact for an entire field. Substring deliberately restores legacy broad matches. |
| No accessible devices returned | Check source IDs, account visibility, direct membership and ReturnHierarchy. Device IDs are not IPs and source groups are not destination groups. |
| Missing interfaces | Without UseSnmp, only WUG assignment/report rows are available. With UseSnmp and IncludeSnmpOnly, check SnmpStatus, device IP and selected vault entries. |
| Traffic-only row has Unknown status | It may have no active assignment, or its report name has no trailing ifIndex. Check the warning and the interface's assignment/report IDs; the helper does not guess. |
| WUG folder is "not an owned static navigation group" | A same-name folder/group has a different type or ownership description. Choose a separate FolderName or investigate the conflict. |
| Old WUG members/groups remain after a re-run | Synchronization is additive. It intentionally does not remove stale members or old categories. Review/remove obsolete configuration through your normal WUG workflow. |
| Old HTML pages remain in the output folder | Obsolete files are not deleted. Use a new dedicated OutputDirectory for a clean pack; do not publish old/unrelated files by accident. |
| WhatIf did not open/write a dashboard | Expected: IndexPath is null. First generate a report without WhatIf and without CreateWugGroups, then preview/apply creation. |
| Tables do not render while the landing page opens | Check access to the dashboard CDN dependencies and browser console/network restrictions. |
| "No local WUG NmConsole installation found" | Run publishing on the WUG server. API connectivity alone is not filesystem access. Supply NmConsolePath for custom installs. |
| Publishing fails on Forms authentication or HTTP 500.19 | Have the IIS administrator review parent authentication and locked sections. Do not remove the protection file to make data accessible. |
| ProgramData write is denied | Grant the intended execution account appropriate access or use an explicitly approved OutputDirectory. No silent per-user fallback is used. |
| All-device run seems slow | It queries each device's assignments and traffic. Start with one device or source group and lastPolled; larger history increases time/size. |
| Execution policy/signature blocks the script | Follow your organization's signed-script policy; do not bypass it blindly. Keep the repository's signed files intact. |

## API and safety limits

- WUG REST supplies stored comments/descriptions, not separately exposed raw
  ifAlias/ifName/ifDescr fields. Optional SNMP reads those fields directly; without it,
  naming depends on WUG discovery/configuration.
- The join uses **device ID + SNMP ifIndex**, not the report's WUG interfaceId.
  Only built-in Interface active monitor assignments are interpreted this way.
- API failures terminate rather than writing a success-shaped partial report.
- No devices/monitors/aliases are created, renamed, deleted, reassigned or disabled.
  The only opt-in WUG modifications are owned navigation groups and additive
  whole-device membership.
- Reports and JSON contain operational metadata and history. Apply file/web
  permissions appropriately. Anyone who can access the complete pack can access
  other group pages and JSON; separate publication is needed for isolation.
- Review inferred categories before applying changes. Shared naming does not prove
  responsibility, tenant membership or authorization.

## Files and further help

| File | Role |
| --- | --- |
| [Example-InterfaceGrouping.ps1](Example-InterfaceGrouping.ps1) | Recommended operator entry: all scopes and all grouping modes. |
| [Invoke-InterfaceGrouping.ps1](Invoke-InterfaceGrouping.ps1) | Explicit devices + named groups, with configurable destination ParentGroupId. |
| [InterfaceGroupingHelpers.ps1](InterfaceGroupingHelpers.ps1) | Internal collection, inference, grouping, WUG synchronization and dashboard export functions. Dot-source for advanced use; not a standalone command to run by itself. |
| [InterfaceGroupWorkflowHelpers.ps1](InterfaceGroupWorkflowHelpers.ps1) | Internal profile validation, review, freshness, health and exclusive run-lock helpers; loaded by InterfaceGroupingHelpers. |
| [Example-InterfaceGroupProfile.json](Example-InterfaceGroupProfile.json) | Editable, no-WUG-writes sample profile for lab device 818. |
| [Invoke-InterfaceGroupProfile.ps1](Invoke-InterfaceGroupProfile.ps1) | Logged profile runner; also used directly by scheduled tasks. |
| [Register-InterfaceGroupScheduledTask.ps1](Register-InterfaceGroupScheduledTask.ps1) | Owned recurring refresh task registration, listing and removal. |
| [Start-InterfaceGroupingSetup.ps1](Start-InterfaceGroupingSetup.ps1) | Guided profile, SNMP, preview/review, approved run and optional scheduling wizard. |
| [InterfaceGroupSnmpHelpers.ps1](InterfaceGroupSnmpHelpers.ps1) | Opt-in generic SNMP credential mapping, IF-MIB reads and inventory enrichment. |
| [InterfaceGroupOperations.ps1](InterfaceGroupOperations.ps1) | Shared readiness/status functions; loaded explicitly by the launcher commands. |
| [Test-InterfaceGroupReadiness.ps1](Test-InterfaceGroupReadiness.ps1) | Structured prerequisite checks, optional write/API probes. |
| [Get-InterfaceGroupStatus.ps1](Get-InterfaceGroupStatus.ps1) | Retained run/failure/health/publication and optional scheduled-task status. |
| [InterfaceDashboardAssets.ps1](InterfaceDashboardAssets.ps1) | Standalone HTML asset embedding using existing bundled dependencies and notices. |
| [Interface-Group-Details.html](Interface-Group-Details.html) | Traffic drill-down fragment injected into dashboards; not a populated report to open directly. |
| [DashboardPublishingHelpers.ps1](../reports/DashboardPublishingHelpers.ps1) | Shared protected pack copy, web.config deployment and actual web-access verification. |
| [Interface grouping architecture and lab notes](../../docs/interface-grouping.md) | API evidence, MVP limits and lab validation context. |

Built-in help:

```powershell
Get-Help .\helpers\interfaces\Example-InterfaceGrouping.ps1 -Full
Get-Help .\helpers\interfaces\Invoke-InterfaceGrouping.ps1 -Examples
```
