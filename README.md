# azure-scripts-tools

A collection of Azure CLI (`az`) shell scripts for Azure automation tasks.
Targets **Linux** and **macOS** (bash 3.2+).

---

## get_sql_vms.sh

List all Azure SQL Server VMs registered with the **SQL IaaS Agent extension**
(`Microsoft.SqlVirtualMachine`) across one or more subscriptions, enrich each VM
with compute details, and optionally query **Change Tracking & Inventory** for
running MSSQL instances.

### What it does

1. Calls `az sql vm list` to find VMs registered with the SQL IaaS extension.
2. Per VM, calls `az vm show` to enrich with `vmSize` and OS image SKU; SQL
   version is parsed from the `sqlImageOffer` field
   (e.g. `"SQL2019-WS2019"` → `"2019"`).
3. Optionally queries **Change Tracking & Inventory** using two complementary
   sources:
   - **Windows Services** — matches the following service name patterns:
     - `MSSQL*` — SQL Server Database Engine (default `MSSQLSERVER` and named
       `MSSQL$INSTANCE`)
     - `MsDtsServer*` — SQL Server Integration Services / SSIS (e.g.
       `MsDtsServer150` for 2019, `MsDtsServer140` for 2017)
     - `SQLServerReportingServices` — SSRS 2017 and later
     - `ReportServer` / `ReportServer$*` — SSRS 2016 and earlier
     - Display names containing `"SQL Server"` as a fallback when the service
       short name column is empty (CT agent schema variant).
   - **Software Inventory** — matches entries whose `SoftwareName` contains
     `"SQL Server"` (`Microsoft SQL Server …`).
   A `Source` column (`WindowsService` / `SoftwareInventory`) indicates which
   data source each row came from. Workspaces are auto-discovered unless you
   pass `-w`.

---

## Requirements

| Tool | Purpose |
|------|---------|
| [`azure-cli`](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | All Azure API calls |
| [`jq`](https://stedolan.github.io/jq/) | JSON processing |
| [`fzf`](https://github.com/junegunn/fzf) *(optional)* | Interactive subscription picker (`-i`) |

The script self-checks `az` and `jq` on startup and exits with a clear error
if either is missing.

### Authentication

```bash
az login          # interactive browser login
az login --use-device-code   # device-code flow (headless/CI)
```

Or use `-i` / `--interactive` to have the script launch `az login` for you
and present an interactive subscription picker.

---

## Installation

```bash
git clone https://github.com/Versiona/azure-scripts-tools.git
cd azure-scripts-tools
chmod +x get_sql_vms.sh
```

No additional dependencies beyond `az` and `jq`.

---

## Usage

```
get_sql_vms.sh [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `-s, --subscription <id>` | Subscription ID to scan. Repeatable or comma-separated. Defaults to the currently active `az` account. |
| `-f, --subscriptions-file <path>` | File with one subscription ID per line (`#` lines are ignored). |
| `-i, --interactive` | Launch `az login` and pick subscriptions interactively (fzf UI if installed, numbered list otherwise). |
| `-g, --resource-group <name>` | Filter SQL VMs to a specific resource group. |
| `-w, --workspace <id>` | Log Analytics workspace customer ID (GUID). If omitted, workspaces are auto-discovered per subscription. |
| `-o, --output <format>` | `table` (default) \| `json` \| `csv` |
| `--vms-file <path>` | Write SQL VM results to this file instead of stdout. |
| `--inv-file <path>` | Write combined Change Tracking inventory to this file instead of stdout. |
| `--svc-file <path>` | Write **Windows Services** rows to this file (activates split mode). |
| `--sw-file <path>` | Write **Software Inventory** rows to this file (activates split mode). |
| `--skip-inventory` | Skip Change Tracking inventory queries (faster). |
| `-v, --verbose` | Print debug output to stderr. |
| `-h, --help` | Show help text. |

---

## Examples

```bash
# Scan the currently active subscription (table output)
./get_sql_vms.sh

# Multiple subscriptions via repeated flags
./get_sql_vms.sh -s "aaaa-..." -s "bbbb-..."

# Multiple subscriptions comma-separated
./get_sql_vms.sh -s "aaaa-...,bbbb-...,cccc-..."

# Load subscriptions from a file
./get_sql_vms.sh -f subscriptions.txt

# Use an explicit Log Analytics workspace
./get_sql_vms.sh -f subscriptions.txt -w "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# CSV export, no inventory — write to file
./get_sql_vms.sh -f subscriptions.txt -o csv --skip-inventory --vms-file sql_vms.csv

# JSON output, single subscription — pipe to jq
./get_sql_vms.sh -s "aaaa-..." -o json | jq '.[] | .vmName'

# Interactive login + subscription picker (requires fzf for best experience)
./get_sql_vms.sh -i

# Interactive + separate CSV files for VMs and combined inventory
./get_sql_vms.sh -i -o csv \
  --vms-file sql_vms.csv \
  --inv-file sql_inventory.csv

# Split inventory: Windows Services and Software Inventory in separate files
./get_sql_vms.sh -f subscriptions.txt -o csv \
  --vms-file sql_vms.csv \
  --svc-file windows_services.csv \
  --sw-file  software_inventory.csv

# Filter to a specific resource group
./get_sql_vms.sh -s "aaaa-..." -g "my-resource-group"

# Write each section to a separate CSV file (combined inventory)
./get_sql_vms.sh -f subscriptions.txt -o csv \
  --vms-file sql_vms.csv \
  --inv-file sql_inventory.csv

# Write VMs to file, stream inventory to stdout
./get_sql_vms.sh -f subscriptions.txt -o json --vms-file vms.json
```

---

## Subscriptions file format

```
# This is a comment
00000000-0000-0000-0000-000000000001
00000000-0000-0000-0000-000000000002
```

Lines starting with `#` and blank lines are ignored.

---

## Output formats

The script produces two independent sections: **SQL Virtual Machines** and
**Change Tracking Inventory**. Each can be written to stdout or redirected to
its own file with `--vms-file` / `--inv-file`. Section banners (`═══ …`) always
go to stderr and never appear in files or piped output.

### table (default)

Human-readable fixed-width table.

**SQL VMs:**
```
SUBSCRIPTION             VM NAME                      RESOURCE GROUP       LOCATION         VM SIZE                    OS IMAGE SKU           SQL SKU      SQL VERSION  LICENSE
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
My Subscription          sql-vm-prod-01               rg-sql               eastus           Standard_D8s_v3            2019-datacenter-core   Developer    2019         AHUB
```

**Change Tracking Inventory:**
```
SUBSCRIPTION             COMPUTER                     SOURCE               INSTANCE (SVC NAME)  DISPLAY NAME                         STATE        LAST SEEN
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
My Subscription          sql-vm-prod-01               WindowsService       MSSQLSERVER          SQL Server (MSSQLSERVER)             Running      2026-03-12 09:00 UTC
My Subscription          sql-vm-prod-01               SoftwareInventory    Microsoft SQL Server 2019  Microsoft SQL Server 2019 v15.0  Installed    2026-03-12 09:00 UTC
```

License values returned by Azure:

| Value | Meaning |
|-------|---------|
| `PAYG` | Pay As You Go |
| `AHUB` | Azure Hybrid Benefit (bring your own SQL Server licence) |
| `DR`   | Disaster Recovery replica (free passive secondary) |

### csv

Suitable for import into Excel / Power BI.

**SQL VMs:**
```
Subscription Name,Subscription ID,VM Name,Resource Group,Location,VM Size,OS Image SKU,SQL SKU,SQL Offer,SQL Version,License Type
My Subscription,aaaa-...,sql-vm-prod-01,rg-sql,eastus,Standard_D8s_v3,2019-datacenter-core,Developer,SQL2019-WS2019,2019,AHUB
```

**Change Tracking Inventory:**
```
Subscription Name,Subscription ID,Computer,Source,Instance Name,Display Name,State,Startup Type,Service Account,Last Seen
My Subscription,aaaa-...,sql-vm-prod-01,WindowsService,MSSQLSERVER,SQL Server (MSSQLSERVER),Running,Automatic,NT Service\MSSQLSERVER,2026-03-12 09:00 UTC
```

### json

Full JSON array, one object per section. Pipe through `jq` for filtering.

---

## Notes

- The **workspace ID** passed to `-w` is the GUID labelled "Workspace ID" on
  the Log Analytics workspace overview page — not the full resource ID.
- Change Tracking & Inventory must be **enabled on the VMs** and data must have
  been collected for inventory queries to return results.
- Inventory queries are automatically **scoped to the VM names discovered** in
  each subscription (or resource group if `-g` is used), so only relevant
  machines are returned. The `Computer` field in Change Tracking is the VM
  hostname, which is usually the same as the Azure VM resource name. If a VM
  uses a different hostname (e.g. domain-joined), use `-v` to inspect the
  computer filter being applied.
- The Windows Services query matches `MSSQL*` (Database Engine), `MsDtsServer*`
  (SSIS), `SQLServerReportingServices` / `ReportServer*` (SSRS), and display
  names containing `"SQL Server"` as a fallback — covering all SQL Server
  service components regardless of CT agent schema version.
- Failures on individual `az` calls (inaccessible subscription, missing
  workspace, etc.) are surfaced as warnings and the scan continues; a single
  error does not abort the whole run.

---

## Safety

The script is **read-only** — it only queries Azure, never creates, modifies, or deletes any resources.

**Azure calls made (all read operations)**

| Command | Purpose |
|---------|---------|
| `az sql vm list` | List SQL IaaS-registered VMs |
| `az vm show` | Read VM compute details |
| `az resource list` | Discover Change Tracking workspaces |
| `az monitor log-analytics workspace show` | Read workspace config |
| `az monitor log-analytics query` | Query inventory logs |

**Minimum required Azure RBAC role:** `Reader` on each subscription. No write permissions needed.

### Verifying before running in production

```bash
# 1. Syntax check — executes nothing
bash -n get_sql_vms.sh

# 2. Run the offline test suite (no Azure login required)
bash tests/run_tests.sh

# 3. Confirm which Azure identity is active
az account show

# 4. Test on a single non-critical subscription first
./get_sql_vms.sh -s "<dev-sub-id>" --skip-inventory
```

---

## Version history

See [CHANGELOG.md](CHANGELOG.md).

Current version: **1.7.0**
