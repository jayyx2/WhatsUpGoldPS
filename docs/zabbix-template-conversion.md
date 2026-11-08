# Zabbix template conversion (experimental)

The standalone [converter](../helpers/converters/Convert-ZabbixTemplateToWUG.ps1) converts Zabbix exports into WhatsUp Gold SNMP monitoring profiles and can optionally create supported monitors in the WUG library. It requires **PowerShell 5.1 or later**, with **no external runtime dependencies**.

Conversion is offline by default. It never polls SNMP targets, creates devices, assigns monitors, installs packages, or executes template scripts/commands. No credentials are needed for conversion. **Only `-ImportToWUG` enables WUG library writes**, using an existing connection.

## Current scope

| Feature | Current behavior |
|---|---|
| YAML, XML, JSON exports | Read local files; recognize the `zabbix_export` root and validate the declared version. |
| Concrete numeric SNMP items | Build raw performance-monitor candidates using the module's SNMP property bags. |
| Numeric OIDs and single `get[OID]` | Preserve the complete OID, including composite instance suffixes, without guessing index boundaries. |
| Polling intervals | Preserve supported fixed whole-minute intervals between 1 and 1440 minutes; no rounding. Missing item delay uses Zabbix's one-minute default. |
| Preprocessing, rate/delta, inventory strings | Preserve redacted source metadata and explicitly defer conversion. No incorrect raw substitute is generated. |
| User macros and linked templates | Resolve non-secret defaults and explicit overrides; resolve parents from supplied same-version local exports. Missing references remain explicit requirements. No downloads. |
| Current-value triggers | Generate SNMP active monitors for supported equality/inequality comparisons and unsigned upper thresholds, preserving problem/healthy polarity. |
| SNMP Table discovery | Generate table active monitors for supported prototype triggers with a single representable literal LLD selector, or an explicit user row-selection policy. Dynamic performance prototypes still require live instance discovery. |
| SNMP traps | Generate passive listeners for portable `snmptrap[...]` payload filters. Listener creation does not translate Zabbix historical alert/recovery logic. |
| Disabled items/prototypes | Exclude from ready output, including children of disabled definitions. |
| Graphs, dashboards and non-SNMP items | Preserve metadata and report unimplemented/out-of-scope translation. |

This is not a universal Zabbix runtime. Complex history/recovery/dependency expressions, preprocessing transforms, advanced LLD filters and unsupported PCRE features remain explicit deferred definitions. YAML parsing is tested separately against the complete pinned official suite described below. Live WUG/device validation is a separate step.

## Usage

Run from the repository root. Example paths below use sibling folders rather than a specific user's machine layout. Input folders are not bundled with this repository; adjust the paths to your local exports, checkouts and desired output locations.

Read one file and inspect the returned profile objects:

```powershell
$profiles = .\helpers\converters\Convert-ZabbixTemplateToWUG.ps1 `
    -Path '..\templates\template_cisco_1900.yaml'

$profiles | Select-Object Template, Completion, Counts
$profiles[0].Definitions | Format-Table Kind, Name, Status
```

Write profiles and reports to an explicit destination:

```powershell
.\helpers\converters\Convert-ZabbixTemplateToWUG.ps1 `
    -Path '..\templates\template_cisco_1900.xml' `
    -OutputDirectory '..\converted-profiles'
```

Use `-TemplateName` for an exact, case-sensitive template identity. Otherwise all templates in the selected files are converted independently. `-Path` accepts multiple export files; `-DependencyPath` supplies additional files used only for inheritance. Select each identity/version once; conflicting local definitions are errors. Directory scanning and automatic version selection are not supported.

```powershell
$profiles = .\helpers\converters\Convert-ZabbixTemplateToWUG.ps1 `
    -Path '..\templates\cisco-child.yaml' `
    -DependencyPath '..\templates\cisco-parent.yaml' `
    -MacroValues @{ '{$POLL_INTERVAL}' = '5m' }
```

Parent items/rules/macros are merged by identity, with local definitions taking precedence. Ambiguous parent conflicts and dependency/macro cycles are errors. Secret/vault macros and context macros are not substituted; do not pass credentials as macro overrides. Source dependency hashes and unresolved requirements are retained.

Use `-WhatIf` to parse/classify without writing anything. Existing output files cause an error unless `-Force` is supplied.

### Optional monitor-template payload

Add `-ExportMonitorTemplates` with `-OutputDirectory` to write ready-only JSON in the WUG monitor-template API envelope. It has `activeMonitors`, `performanceMonitors`, and `passiveMonitors` arrays, populated according to the supported source definitions.

This payload **does not assign monitors to devices or configure polling intervals**. Assignment timing and units remain in the profile. Do not assume importing the monitor library payload alone reproduces the original monitoring configuration.

The module property bags are used as the offline contract; collection with a complete OID and empty instance has **not yet been verified against a live WUG server**.

### SNMP active and table rules

Supported trigger forms are `last(/Template/key)<operator>number` and legacy `{Template:key.last()}<operator>number`. The reference must resolve to an enabled, untransformed SNMP item in the selected template's lineage. Historical functions, dependent triggers, custom recovery, multiple-problem events, manual close and unresolved macros are not approximated.

- Scalar `=` / `<>` use a nonnegative Int32 constant and explicit problem/healthy polarity.
- Scalar unsigned `> N` / `>= N` use the equivalent healthy range, with a positive Int32 threshold.
- Table `=`, `<>`, `>` and `<` use the native table comparator and polarity.
- Source fixed active polling intervals from 10 to 86400 seconds are retained as assignment requirements, not automatically assigned.

Table prototypes must use a numeric column OID followed by the complete `.{#SNMPINDEX}` suffix. A single positive literal LLD regex such as `^Fan1$` maps to equality; a plain literal substring maps to contains. Complex regex/boolean filters, LLD overrides and unsupported discovery expressions are deferred.

For a rule without a directly representable filter, supply an explicit selector. For example, **after verifying that a Cisco fan-state column reports positive status enums**, this policy selects those rows:

```powershell
$tablePolicy = @{
    'ciscoEnvMonFanStatusDescr' = @{
        Oid      = '1.3.6.1.4.1.9.9.13.1.4.1.3'
        Operator = 'gt'
        Value    = '0'
    }
}
$profiles = .\helpers\converters\Convert-ZabbixTemplateToWUG.ps1 `
    -Path '..\templates\template_cisco_2960.yaml' `
    -TemplateName 'Cisco_2960' -TableDiscovery $tablePolicy
```

An override is explicitly labeled `ExplicitRowSelectionPolicy`: it is a user policy, not a claim of equivalent Zabbix row selection. No empty-string "match all" criterion, table index or trap enterprise OID is guessed. Table discovery/rescan and lost-resource lifecycle scheduling still need separate configuration.

Trap candidates are labeled `EventFilterOnly`. The portable filter subset preserves case sensitivity and XML-escapes patterns; supported POSIX character classes are translated to explicit ASCII classes. Zabbix global regex references, unsupported PCRE constructs, fallback routing and instance-dependent trap prototypes remain deferred. **A WUG trap listener is not a conversion of a Zabbix `nodata()` or recovery trigger.**

### Optional automatic library creation

After reviewing profiles, explicitly connect using the module's existing credential workflow:

```powershell
# Establish your connection separately using Connect-WUGServer.

# Offline preview: no API calls, even without a connection.
$preview = .\helpers\converters\Convert-ZabbixTemplateToWUG.ps1 `
    -Path '..\templates\template_cisco_1900.yaml' -ImportToWUG -WhatIf

# Explicit creation in the connected server's monitor library.
$result = .\helpers\converters\Convert-ZabbixTemplateToWUG.ps1 `
    -Path '..\templates\template_cisco_1900.yaml' `
    -ImportToWUG -MonitorNamePrefix 'Converted - '

$result[0].LibraryImportResults | Format-Table Name, BaseType, MonitorId, Action
```

The [importer](../helpers/converters/ZabbixWugImport.ps1):

1. Imports only `Ready` candidates and warns about excluded definitions.
2. Reads the existing monitor templates with pagination and redacted sensitive fields.
3. Checks all names/configurations before any write; conflicting configurations fail rather than updating/reusing a different monitor.
4. Deduplicates equivalent requested names and creates only missing monitors in batches of at most 50.
5. Disables transient retries for creation, validates the API's successful count and complete ID map, then rereads the library to reconcile created IDs/configurations.

Existing monitors are reused only when class, base type, property bags and active discovery flag match. Additional/different server property bags conservatively count as a conflict. Use `-MonitorNamePrefix` to avoid collisions; the importer never overwrites/deletes monitors. `-Confirm` is honored. A failed batch can have partially created monitors: errors are surfaced, with no automatic rollback or blind retry.

`LibraryImportResults` are returned on the in-memory profiles; profile/report files remain offline conversion snapshots. A `-WhatIf` receipt is `PlannedUnverified`, not proof that a name is missing on the server.

## Output contract

Each template produces:

- `<id>.profile.json`: version `0.2` profile with source/dependency hashes, sanitized metadata, resolution requirements, definitions, candidate parameters, polling requirements and counts.
- `<id>.report.json`: compact per-definition statuses and reason codes.
- `<id>.monitors.json`: optional ready-only WUG API monitor templates.

Files use UTF-8 BOM. Filenames are deterministic hashes of export version and template identity. Repeated conversion of an unchanged source is deterministic. Definition IDs identify source locations, **not semantic equivalence across edited or reordered templates**. A later deployment workflow must compare configuration, not reuse monitor names/IDs blindly.

Definition states are `Ready`, `NeedsInput`, `Deferred`, `Unsupported`, `Disabled`, and `Invalid`. `Ready` means the offline mapping matches the current module contract, **not** that live collection is verified. Every profile is labeled `OfflineOnly`.

`Completion` is `Partial` if any definition is not ready, `Empty` if no definitions were found, or `ConvertedOffline` when all enumerated definitions are ready. Partial/empty results also produce a warning; parse/schema failures throw errors. Counts describe definitions, not distinct integrations or devices.

Source-export triggers and graphs, including dependency exports, are retained conservatively in each profile. Current-value triggers are translated only when their host/item reference resolves to the selected lineage; cross-host conditions are deferred. Unrecognized metadata remains in sanitized source fields rather than being silently treated as translated.

Known password/community/token fields and macro defaults are redacted. Free-form descriptions, scripts, commands, request bodies, headers and URLs are omitted. This is **not a general secret detector**: use template exports without embedded secrets and review output before sharing. The profile intentionally is not a byte-for-byte/lossless copy; retain the original export separately.

## YAML reader and Zabbix projection

The private [reader](../helpers/converters/YamlReader.ps1) and [representation helpers](../helpers/converters/YamlNodes.ps1) are written in PowerShell 5.1 with no external parser dependency. General YAML loading is separate from Zabbix export validation:

- `Read-WUGYamlStream -Text $text -Schema Core` returns documents whose roots are representation nodes. `Failsafe`, `JSON` and `Core` scalar schemas are supported; Core is the default.
- Nodes retain scalar spelling, style, tag, anchor and source location. `ResolvedTag` and `Canonical` describe resolved scalar meaning. Integer and decimal coefficient/exponent canonicalization retain exact values without binary floating-point rounding, including large integers and exponents.
- Mappings retain ordered key/value node pairs, allowing scalar, null, sequence and mapping keys. Duplicate detection uses schema-aware structural equality: mapping order is irrelevant, string identity is ordinal, and equivalent numeric spellings compare equal within their resolved type.
- Aliases retain object identity, including recursive graphs and anchor shadowing. Unknown/forward aliases are errors; recursive aliases do not require tree expansion.
- Block/flow collections, compact collections, explicit keys, multiline scalars, Unicode escapes, literal/folded blocks, tags/directives and document streams are supported. Anchors and tag directives reset between documents.
- Core tags are checked against node shape and scalar content. Unrecognized tags remain opaque data and **never instantiate objects**.
- Compatible non-1.2 `%YAML 1.x` directives produce warnings and use YAML 1.2 syntax with the selected schema; incompatible major versions fail. Reserved directives are ignored with explicit warnings.
- `-SyntaxOnly` parses representation nodes without schema resolution or semantic duplicate-key checks. The official event gate uses this mode; semantic loading is covered by separate regression tests.

`Read-ZabbixYaml` preserves the converter's existing native-tree contract through an explicit projection. Scalar spellings are preserved except resolved null; explicit `!!str null` stays a string. Mappings become ordinal string-keyed dictionaries and aliases become independent tree copies. Merge keys remain a Zabbix compatibility extension with explicit-field precedence, not part of the general Core schema.

Valid general YAML with complex/non-string field names, recursive graphs or opaque tags can therefore fail **Zabbix export validation**. Those are export-shape restrictions, not YAML syntax limitations. The converter requires **exactly one export document per file**; the private wrapper's `-AllDocuments` option does not automatically merge or select exports.

Resource limits remain explicit: 64 levels of reader/projection nesting, a 16 Mi-character reader input limit, a 16 MiB export-file limit, and at most 100,000 alias-expanded projection nodes. Malformed syntax, non-printable raw characters and unpaired surrogates fail with source/line diagnostics. Invalid flow syntax previously accepted permissively is now rejected.

### Pinned official conformance gate

The [conformance harness](../helpers/test/Invoke-WUGYamlConformanceTest.ps1) passes **402 of 402 cases on both Windows PowerShell 5.1 and PowerShell 7** against [yaml/yaml-test-suite](https://github.com/yaml/yaml-test-suite) data revision `6ad3d2c62885d82fc349026c136ef560838fdf3d`, with no exclusions.

It compares complete event streams ordinally for valid cases and requires source/line parser errors for invalid cases. Unexpected internal exceptions are failures, not successful rejection. The harness verifies the pinned revision, clean checkout and complete inventory before running. This is reproducible evidence for the complete pinned suite, not proof over every possible input or future suite revision. Specification reference: [YAML 1.2.2](https://yaml.org/spec/1.2.2/).

Fetch the public test data separately; the converter never downloads or executes it:

```powershell
git clone --single-branch --branch data `
    https://github.com/yaml/yaml-test-suite.git '..\yaml-test-suite'
git -C '..\yaml-test-suite' checkout 6ad3d2c62885d82fc349026c136ef560838fdf3d

.\helpers\test\Invoke-WUGYamlConformanceTest.ps1 `
    -SuiteRoot '..\yaml-test-suite' `
    -ReportPath '..\yaml-conformance.json'
```

Keep reports outside the suite checkout. A nonzero exit code fails the gate. Optional `-CaseId` runs help diagnose individual cases but report `FullGate = false`; they do not substitute for the complete run.

XML external entities/DTDs are prohibited. Export versions currently accepted are 5.0, 5.2, 5.4, 6.0, 6.2, 6.4, 7.0, 7.2 and 7.4; this recognizes their basic export layout, not every feature in every version.

## Tests and Cisco validation path

Run the offline harness in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\helpers\test\Invoke-WUGZabbixConversionTest.ps1
```

Optionally also test actual Cisco exports from a local checkout/download. Set `-CommunityTemplateRoot` to the folder containing `Network_Devices` (ZIP downloads may add an extra enclosing folder):

```powershell
.\helpers\test\Invoke-WUGZabbixConversionTest.ps1 `
    -CommunityTemplateRoot '..\community-templates'
```

Synthetic fixtures are generated in a private temporary directory and removed afterwards. Community files are read-only and are not redistributed. The optional tests cover Cisco 1900 and 2960 XML/YAML exports; these names are fixtures, not a claim that either model matches the intended live device.

The current regression run passes **62 groups on both Windows PowerShell 5.1 and PowerShell 7**, including the four community Cisco fixtures. This is offline parsing/conversion coverage, not live E2E validation. Unsupported monitor definitions remain visible in reports.

The harness also exercises multiline flow syntax, tags/directives, complex keys and structural equality, all three scalar schemas, exact large-number canonicalization, recursive alias identity, opaque tags, stream scope, Unicode rejection and source-line diagnostics. An expanded-syntax Zabbix export must produce exactly the same WUG payload as the baseline export; multi-document exports must be rejected.

A deterministic generated test additionally checks 60 string/null/collection trees in both compact and pretty-printed JSON form (120 YAML-compatible documents), comparing complete tree shapes and scalar values. These checks require no third-party YAML package.

Monitor tests cover active polarity/range boundaries, table selectors, trap filter XML, macro/inheritance resolution, and a simulated WUG library with creation/reuse, pagination, preflight conflicts, partial failures, ID-map validation, reconciliation and 50-monitor batches. The harness never contacts a real server.

For the later live phase, select a template matching the in-house Cisco device and firmware, store SNMP credentials in the existing discovery vault, validate OIDs/indexes/units and healthy/failing checks, then add explicit WUG deployment. Do not put credentials in template files, command history, or conversion reports.
