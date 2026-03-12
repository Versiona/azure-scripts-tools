# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.2.0]: https://github.com/your-org/az_scripts/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/your-org/az_scripts/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/your-org/az_scripts/releases/tag/v1.0.0
