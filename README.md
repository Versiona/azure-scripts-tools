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
3. Optionally queries **Change Tracking & Inventory** for running MSSQL
   instances. Both **Windows Services** (`MSSQLSERVER` / `MSSQL$<name>`) and
   **Software Inventory** (`Microsoft SQL Server …`) are queried so that either
   Change Tracking configuration returns results. A `Source` column indicates
   which data source each row came from.
   Workspaces are auto-discovered unless you pass `-w`.

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
| `--inv-file <path>` | Write Change Tracking inventory results to this file instead of stdout. |
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

# CSV export, no inventory
./get_sql_vms.sh -f subscriptions.txt -o csv --skip-inventory > sql_vms.csv

# JSON output, single subscription
./get_sql_vms.sh -s "aaaa-..." -o json | jq '.[] | .vmName'

# Interactive login + subscription picker (requires fzf for best experience)
./get_sql_vms.sh -i

# Interactive + CSV export
./get_sql_vms.sh -i -o csv --skip-inventory > sql_vms.csv

# Filter to a specific resource group
./get_sql_vms.sh -s "aaaa-..." -g "my-resource-group"

# Write each section to a separate CSV file
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

### table (default)

Human-readable fixed-width table printed to stdout.

```
SUBSCRIPTION             VM NAME                      RESOURCE GROUP       LOCATION         VM SIZE                    OS IMAGE SKU           SQL SKU      SQL VERSION  LICENSE
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
My Subscription          sql-vm-prod-01               rg-sql               eastus           Standard_D8s_v3            2019-datacenter-core   Developer    2019         AHUB
```

License values returned by Azure:

| Value | Meaning |
|-------|---------|
| `PAYG` | Pay As You Go |
| `AHUB` | Azure Hybrid Benefit (bring your own SQL Server licence) |
| `DR`   | Disaster Recovery replica (free passive secondary) |

### csv

Suitable for import into Excel / Power BI.

```
Subscription Name,Subscription ID,VM Name,Resource Group,Location,VM Size,OS Image SKU,SQL SKU,SQL Offer,SQL Version,License Type
My Subscription,aaaa-...,sql-vm-prod-01,rg-sql,eastus,Standard_D8s_v3,2019-datacenter-core,Developer,SQL2019-WS2019,2019,AHUB
```

### json

Full JSON array, one object per VM. Pipe through `jq` for filtering.

---

## Notes

- The **workspace ID** passed to `-w` is the GUID labelled "Workspace ID" on
  the Log Analytics workspace overview page — not the full resource ID.
- Change Tracking & Inventory must be **enabled on the VMs** and data must have
  been collected for inventory queries to return results.
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

Current version: **1.5.0**
