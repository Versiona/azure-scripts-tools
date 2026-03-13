# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.6.0] – 2026-03-12

### Added
- Windows Services KQL now also detects **SSIS** and **SSRS** instances:
  - `MsDtsServer*` — SQL Server Integration Services (all versions; e.g.
    `MsDtsServer150` for 2019, `MsDtsServer140` for 2017, etc.)
  - `SQLServerReportingServices` — SSRS 2017 and later
  - `ReportServer` / `ReportServer$*` — SSRS 2016 and earlier (default and
    named instances)
- These appear in inventory output alongside Database Engine entries with
  `Source = "WindowsService"` and their service short name as `InstanceName`.
- The display-name fallback (`contains "SQL Server"`) already caught SSIS and
  SSRS display names; the new service-name filters provide a more reliable
  primary match.

### Changed
- Version bumped to `1.6.0`.

---

## [1.5.2] – 2026-03-12

### Fixed
- Windows Services KQL: the service short name (`MSSQL$INSTANCENAME`,
  `MSSQLSERVER`) may be stored in `SoftwareName`, `Name`, or `ServiceName`
  depending on the CT agent version. The `svc` block now uses
  `extend _svcName = coalesce(column_ifexists("SoftwareName",""),
  column_ifexists("Name",""), column_ifexists("ServiceName",""), "")` and
  filters on `_svcName startswith "MSSQL"`, ensuring named instances are found
  regardless of which column the agent populates.
- `InstanceName` is now resolved from the same coalesced `_svcName` value,
  so it correctly reflects the service key (e.g. `MSSQL$MYINST`) rather than
  potentially falling back to a display name.

### Changed
- Version bumped to `1.5.2`.

---

## [1.5.1] – 2026-03-12

### Changed
- Windows Services KQL filter now also matches on display name containing
  `"SQL Server"` (columns `CurrentServiceName` / `ServiceDisplayName`), in
  addition to service names starting with `MSSQL` or `MSSQL$`. This catches
  services whose internal name doesn't follow the `MSSQL*` convention but
  whose display name identifies them as a SQL Server instance.
- Version bumped to `1.5.1`.

---

## [1.5.0] – 2026-03-12

### Added
- `--vms-file <path>`: write SQL VM results to a file instead of stdout.
  Creates or overwrites the file; logs the path and confirms on completion.
- `--inv-file <path>`: write Change Tracking inventory results to a file
  instead of stdout.
- Both flags can be used independently or together, and work with all
  `-o` formats (`table`, `csv`, `json`).

### Changed
- Section banners (`═══ SQL Virtual Machines ═══` etc.) now go to **stderr**
  instead of stdout, so they never appear in redirected output or files.
- Version bumped to `1.5.0`.

---

## [1.4.4] – 2026-03-12

### Fixed
- `jq` "unfinished JSON term at EOF" error on inventory results: `jq` outputs
  pretty-printed (multi-line) JSON by default, but the collection loop was
  reading output one line at a time via `while IFS= read -r batch`, so `batch`
  contained only the first line (e.g. `[`) rather than the full array.
  Fixed by:
  1. Adding `-c` to the `jq` call in `process_subscription_inventory` so each
     workspace result is emitted as compact single-line JSON.
  2. Replacing the line-by-line `while read` loop in `main()` with a single
     capture of all inventory output, then one `jq -s 'add // []'` merge.

### Changed
- Version bumped to `1.4.4`.

---

## [1.4.3] – 2026-03-12

### Fixed
- KQL inventory query no longer scans the entire workspace. VM names
  discovered per subscription are now passed as a
  `| where Computer in~ (...)` filter in both the WindowsServices and
  Software Inventory let-blocks, preventing thousands of unrelated results
  and the jq EOF parse error caused by oversized responses.
- The two subscription loops (VM collection and inventory) are now merged
  into one so VM names are available to scope the inventory query in the
  same pass.

### Changed
- If no VMs are found in a subscription the inventory query for that
  subscription is skipped entirely.
- Version bumped to `1.4.3`.

---

## [1.4.2] – 2026-03-12

### Fixed
- KQL project error: `SoftwareVersion` column may not exist in the
  `ConfigurationData` schema. Wrapped in `column_ifexists("SoftwareVersion", "")`.

### Changed
- Version bumped to `1.4.2`.

---

## [1.4.1] – 2026-03-12

### Fixed
- KQL `SEM0255` error: `format_datetime()` does not accept literal text in the
  format string. The `" UTC"` suffix is now appended via `strcat()`:
  `strcat(format_datetime(TimeGenerated,"yyyy-MM-dd HH:mm"), " UTC")`.

### Changed
- Version bumped to `1.4.1`.

---

## [1.4.0] – 2026-03-12

### Added
- **Progress bar** during VM enrichment: shows filled/empty blocks, percentage,
  count, and current VM name; redraws in place on stderr and is suppressed when
  stderr is not a TTY.
- **Verbose KQL output**: `--verbose` now prints the full KQL query to stderr
  before each Log Analytics call to ease debugging.
- **Version + PID at startup**: `get_sql_vms.sh v1.4.0 (PID <n>)` logged on
  every run.
- **Software Inventory source** in Change Tracking queries: the KQL now unions
  both `WindowsServices` (MSSQLSERVER / MSSQL$\<name\>) and `Software` entries
  (Microsoft SQL Server) so that either Change Tracking configuration returns
  results.
- **`Source` column** in inventory output (`WindowsService` or
  `SoftwareInventory`) — present in table, CSV, and JSON formats.

### Fixed
- **Only 1 VM returned despite many found**: `az` commands inside the VM loop
  consumed the loop's stdin when the loop used process substitution. Fixed by
  routing the VM stream through file descriptor 3
  (`done 3< <(...)` / `read <&3`).
- **Garbled escape codes** (`\033[1m`, etc.) in output: terminal colors now use
  `tput` instead of hardcoded ANSI sequences, guarded by a TTY check.
- **CRLF (`\r`) characters** in subscription names and other `az -o tsv` output
  (common on WSL): all TSV captures now pipe through `tr -d '\r'`.
- **`unknown` for SQL SKU, SQL Version, and License fields**: newer Azure CLI
  returns these at the top level rather than under `.properties`; fixed with
  dual-path expressions such as
  `(.properties.sqlImageSku // .sqlImageSku) // "unknown"`.
- **No SQL VMs found with `-s`/`-g`**: `az sql vm list` and workspace discovery
  now pass `--subscription` directly to every `az` call instead of relying on
  `az account set` context which could silently fail.
- **KQL `SEN0100` error** ("operator failed to resolve scalar expression named
  `ServiceName`"): optional columns are now wrapped in `column_ifexists()` so
  the query runs against any workspace schema.

### Changed
- Error output from `az` calls is now surfaced as warnings instead of being
  silently swallowed, making failures easier to diagnose.
- Version bumped to `1.4.0`.

---

## [1.3.0] – 2026-03-12

### Added
- **License Type** column in all output formats (`PAYG`, `AHUB`, `DR`).
  Sourced from `properties.sqlServerLicenseType` returned by `az sql vm list`.
  - Table output: new `LICENSE` column after `SQL VERSION`.
  - CSV output: new `License Type` column.
  - JSON output: new `sqlLicense` field per VM object.

### Changed
- Version bumped to `1.3.0`.

---

## [1.2.0] – 2026-03-12

### Added
- `-i` / `--interactive` flag: launches `az login` and presents an interactive
  subscription picker before scanning begins.
- `fzf` multi-select UI (arrow keys, Tab to toggle, Ctrl-A to select all) when
  `fzf` is installed; falls back gracefully to a numbered list otherwise.
- `interactive_login_and_select()` internal function.

### Changed
- `check_prereqs` no longer requires an active `az` session when `-i` is used
  (login happens inside the interactive flow).
- Error message for unauthenticated runs now hints at `-i`:
  `Not authenticated. Run: az login (or use -i for interactive mode)`.
- Version bumped to `1.2.0`.

---

## [1.1.0] – 2025-09-01

### Added
- `normalize_la_output()` helper to handle both the flat-array response and
  the `{ "tables": [...] }` envelope returned by different `az` CLI versions
  when running Log Analytics queries.
- `--skip-inventory` flag to bypass Change Tracking queries for faster scans.
- `-v` / `--verbose` flag for debug output on stderr.
- Auto-discovery of Change Tracking workspaces via
  `Microsoft.OperationsManagement/solutions` resource listing.

### Changed
- SQL version is now parsed from `sqlImageOffer`
  (e.g. `"SQL2019-WS2019"` → `"2019"`) instead of a static lookup.
- CSV output includes `sqlOffer` column.
- `dbg()` log helper added; all verbose output routed through it.

### Fixed
- Graceful handling of subscriptions where `az sql vm list` returns an empty
  result or errors out — continues to the next subscription instead of aborting.

---

## [1.0.0] – 2025-06-01

### Added
- Initial release of `get_sql_vms.sh`.
- Lists VMs registered with the SQL IaaS extension
  (`Microsoft.SqlVirtualMachine`) using `az sql vm list`.
- Enriches each VM with `vmSize` and OS image SKU via `az vm show`.
- Queries Change Tracking for running MSSQL Windows services
  (`ConfigurationData` table, `SoftwareName startswith "MSSQL"`).
- Subscription input via `-s` (repeatable / comma-separated) or
  `-f` (file with one ID per line).
- `-g` / `--resource-group` filter.
- `-w` / `--workspace` explicit Log Analytics workspace override.
- Output formats: `table`, `json`, `csv`.
- Color logging helpers (`log`, `ok`, `warn`, `err`, `dbg`) writing to stderr;
  TTY-guarded so colors are suppressed when stderr is not a terminal.
- Self-check for required tools (`az`, `jq`) with actionable error messages.

[1.6.0]: https://github.com/Versiona/azure-scripts-tools/compare/v1.5.2...v1.6.0
[1.5.2]: https://github.com/Versiona/azure-scripts-tools/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/Versiona/azure-scripts-tools/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/Versiona/azure-scripts-tools/compare/v1.4.4...v1.5.0
[1.4.4]: https://github.com/Versiona/azure-scripts-tools/compare/v1.4.3...v1.4.4
[1.4.3]: https://github.com/Versiona/azure-scripts-tools/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/Versiona/azure-scripts-tools/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/Versiona/azure-scripts-tools/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/Versiona/azure-scripts-tools/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/Versiona/azure-scripts-tools/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/Versiona/azure-scripts-tools/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Versiona/azure-scripts-tools/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Versiona/azure-scripts-tools/releases/tag/v1.0.0
