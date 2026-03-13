#!/usr/bin/env bash
# =============================================================================
# get_sql_vms.sh  –  List Azure SQL Server VMs with Change Tracking inventory
# =============================================================================
# Lists VMs registered with the SQL IaaS extension across one or more
# subscriptions, enriches each with compute details, then queries Change
# Tracking & Inventory for running MSSQL instances.
#
# Requirements : azure-cli (az), jq
# Platforms    : Linux, macOS (bash 3.2+)
# =============================================================================
set -euo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly VERSION="1.7.0"

# ─── Terminal colors (only when stderr is a TTY and tput is available) ────────
if [[ -t 2 ]] && command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    BOLD="$(tput bold)"   RED="$(tput setaf 1)"  GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)" BLUE="$(tput setaf 4)" CYAN="$(tput setaf 6)"
    NC="$(tput sgr0)"
else
    BOLD='' RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# ─── Defaults (overridden by CLI options) ─────────────────────────────────────
SUBSCRIPTIONS=()          # populated via -s / -f; defaults to current account
SUBSCRIPTIONS_FILE=""
RESOURCE_GROUP=""
WORKSPACE_ID=""
OUTPUT_FORMAT="table"
VMS_OUTPUT_FILE=""         # --vms-file: write SQL VM results here; empty = stdout
INV_OUTPUT_FILE=""         # --inv-file: write combined inventory here; empty = stdout
SVC_OUTPUT_FILE=""         # --svc-file: write Windows Services rows here (split mode)
SW_OUTPUT_FILE=""          # --sw-file:  write Software Inventory rows here (split mode)
SKIP_INVENTORY=false
VERBOSE=false
INTERACTIVE=false

# ─── Logging ──────────────────────────────────────────────────────────────────
log()  { printf "${BLUE}▸${NC} %s\n"    "$*" >&2; }
ok()   { printf "${GREEN}✓${NC} %s\n"   "$*" >&2; }
warn() { printf "${YELLOW}⚠${NC}  %s\n" "$*" >&2; }
err()  { printf "${RED}✗${NC}  %s\n"    "$*" >&2; }
dbg()  { $VERBOSE && printf "${CYAN}·${NC} %s\n" "$*" >&2 || true; }
die()  { err "$*"; exit 1; }

# ─── Progress bar (stderr, redraws in place) ──────────────────────────────────
# Usage: progress_bar <current> <total> <label>
progress_bar() {
    [[ -t 2 ]] || return 0          # skip if stderr is not a TTY
    local cur=$1 total=$2 label=$3
    local bar_width=40
    local filled=$(( bar_width * cur / total ))
    local empty=$(( bar_width - filled ))
    local pct=$(( 100 * cur / total ))
    local bar filled_str empty_str
    filled_str=$(printf '%0.s█' $(seq 1 "$filled") 2>/dev/null || printf '%*s' "$filled" '' | tr ' ' '█')
    empty_str=$(printf '%0.s░' $(seq 1 "$empty")   2>/dev/null || printf '%*s' "$empty"  '' | tr ' ' '░')
    bar="${GREEN}${filled_str}${NC}${empty_str}"
    printf "\r  ${bar} ${BOLD}%3d%%${NC} (%d/%d) %s " \
        "$pct" "$cur" "$total" "$label" >&2
    [[ "$cur" -ge "$total" ]] && printf "\n" >&2
}

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}${SCRIPT_NAME}${NC} v${VERSION}
List Azure SQL Server VMs and query Change Tracking for running MSSQL instances.

${BOLD}USAGE${NC}
  ${SCRIPT_NAME} [OPTIONS]

${BOLD}OPTIONS${NC}
  -s, --subscription  <id>       Subscription ID to scan. Repeatable, or
                                 comma-separated. Defaults to current account.
  -f, --subscriptions-file <path> File with one subscription ID per line
                                 (lines starting with # are ignored).
  -g, --resource-group <name>    Filter to a specific resource group
  -w, --workspace  <id>          Log Analytics workspace customer ID (GUID).
                                 If omitted, workspaces are auto-detected per
                                 subscription.
  -i, --interactive              Log in to Azure and pick subscriptions
                                 interactively (fzf UI if installed, numbered
                                 list otherwise).
  -o, --output  <format>         table | json | csv   (default: table)
      --vms-file  <path>         Write SQL VM results to this file instead of
                                 stdout. Creates or overwrites the file.
      --inv-file  <path>         Write combined Change Tracking inventory to this
                                 file instead of stdout.
      --svc-file  <path>         Write Windows Services rows to this file
                                 (activates split mode; see below).
      --sw-file   <path>         Write Software Inventory rows to this file
                                 (activates split mode; see below).
      --skip-inventory           Skip Change Tracking inventory queries
  -v, --verbose                  Debug output
  -h, --help                     Show this help

${BOLD}EXAMPLES${NC}
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} -s "aaa-..." -s "bbb-..." -o csv
  ${SCRIPT_NAME} -s "aaa-...,bbb-...,ccc-..."
  ${SCRIPT_NAME} -f subscriptions.txt -o json
  ${SCRIPT_NAME} -f subscriptions.txt -w "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  ${SCRIPT_NAME} -i
  ${SCRIPT_NAME} -i -o csv --skip-inventory
  ${SCRIPT_NAME} -f subs.txt -o csv --vms-file vms.csv --inv-file inventory.csv
  ${SCRIPT_NAME} -f subs.txt -o csv --svc-file services.csv --sw-file software.csv

${BOLD}SUBSCRIPTIONS FILE FORMAT${NC}
  # This is a comment
  00000000-0000-0000-0000-000000000001
  00000000-0000-0000-0000-000000000002

${BOLD}SPLIT MODE${NC}
  When --svc-file or --sw-file is specified, inventory output is split by
  source: Windows Services rows go to --svc-file and Software Inventory rows
  go to --sw-file. If only one split flag is given, the other source is written
  to stdout. --inv-file (combined) can be used alongside split flags.

${BOLD}NOTES${NC}
  The workspace ID is the GUID shown in the Log Analytics workspace overview
  page as "Workspace ID" (Customer ID), not the full resource ID.
  Change Tracking & Inventory must be enabled on the VMs and data must have
  been collected for inventory queries to return results.
EOF
}

# ─── Prerequisites ────────────────────────────────────────────────────────────
check_prereqs() {
    local miss=()
    command -v az >/dev/null 2>&1 || miss+=("az (Azure CLI)")
    command -v jq >/dev/null 2>&1 || miss+=("jq")
    [[ ${#miss[@]} -eq 0 ]] || die "Missing required tools: ${miss[*]}"

    if ! $INTERACTIVE; then
        az account show >/dev/null 2>&1 \
            || die "Not authenticated. Run: az login (or use -i for interactive mode)"
    fi
}

# ─── Load subscriptions from a file ──────────────────────────────────────────
load_subscriptions_file() {
    local file=$1
    [[ -f "$file" ]] || die "Subscriptions file not found: $file"
    while IFS= read -r line; do
        # strip inline comments, leading/trailing whitespace
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        SUBSCRIPTIONS+=("$line")
    done < "$file"
}

# ─── Interactive login + subscription selection ───────────────────────────────
interactive_login_and_select() {
    log "Launching Azure login..."
    az login >/dev/null 2>&1 || die "Azure login failed."
    ok "Authenticated"

    log "Fetching available subscriptions..."
    local subs_json
    subs_json=$(az account list --query '[].{id:id,name:name,state:state}' \
        --all -o json 2>/dev/null)

    local count
    count=$(jq 'length' <<<"$subs_json")
    [[ "$count" -eq 0 ]] && die "No subscriptions found for this account."

    # Build display lines — fixed-width columns for both fzf and numbered fallback
    local display
    display=$(jq -r '.[] | "\(.name)\t\(.id)\t\(.state)"' <<<"$subs_json" \
        | awk -F'\t' '{ printf "%-45s  %-38s  %s\n", $1, $2, $3 }')

    local selected

    if command -v fzf >/dev/null 2>&1; then
        # ── fzf path: arrow keys, Tab=toggle, Enter=confirm, Ctrl-A=all ──────
        selected=$(fzf --multi \
            --prompt="Subscriptions > " \
            --header=$'TAB / Space = toggle   Enter = confirm   Ctrl-A = select all\n' \
            --layout=reverse \
            --height=50% \
            --min-height=12 \
            --marker="●" \
            --pointer="▶" \
            --color="header:italic,marker:green,pointer:cyan" \
            --bind="ctrl-a:select-all" \
            <<<"$display" || true)
    else
        # ── Numbered fallback (no fzf) ────────────────────────────────────────
        warn "fzf not found – using numbered selection  (install fzf for a better UI)"
        printf "\n"
        local i=1
        while IFS= read -r line; do
            printf "  %3d)  %s\n" "$i" "$line"
            (( i++ )) || true
        done <<<"$display"
        printf "\n"
        printf "Enter numbers separated by commas, or 'all': "
        local input
        read -r input </dev/tty

        if [[ "$input" == "all" ]]; then
            selected="$display"
        else
            selected=""
            IFS=',' read -ra picks <<< "$input"
            for pick in "${picks[@]}"; do
                pick="${pick// /}"          # trim spaces
                [[ "$pick" =~ ^[0-9]+$ ]] || { warn "Ignoring invalid entry: $pick"; continue; }
                local picked_line
                picked_line=$(sed -n "${pick}p" <<<"$display")
                [[ -n "$picked_line" ]] && selected+="$picked_line"$'\n'
            done
        fi
    fi

    [[ -z "$selected" ]] && die "No subscriptions selected."

    # Extract UUIDs from selected display lines
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local sid
        sid=$(echo "$line" \
            | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
            | head -1 || true)
        [[ -n "$sid" ]] && SUBSCRIPTIONS+=("$sid")
    done <<<"$selected"

    [[ ${#SUBSCRIPTIONS[@]} -eq 0 ]] && die "Could not parse subscription IDs from selection."
    ok "Selected ${#SUBSCRIPTIONS[@]} subscription(s)"
}

# ─── Fetch all SQL VMs in a subscription ─────────────────────────────────────
fetch_sql_vms() {
    local sub_id=$1
    local args=(--subscription "$sub_id")
    [[ -n "$RESOURCE_GROUP" ]] && args+=(--resource-group "$RESOURCE_GROUP")
    dbg "  az sql vm list --subscription $sub_id ${RESOURCE_GROUP:+--resource-group $RESOURCE_GROUP}"
    local result
    result=$(az sql vm list "${args[@]}" -o json 2>&1) || {
        warn "  az sql vm list failed: $result"
        echo "[]"
        return 0
    }
    echo "$result"
}

# ─── Get compute-level details for one VM ─────────────────────────────────────
fetch_vm_compute() {
    local name=$1 rg=$2
    dbg "    az vm show: $name ($rg)"
    az vm show \
        --name "$name" \
        --resource-group "$rg" \
        --query '{
            vmSize:         hardwareProfile.vmSize,
            imageSku:       storageProfile.imageReference.sku,
            imageOffer:     storageProfile.imageReference.offer,
            imagePublisher: storageProfile.imageReference.publisher
        }' \
        -o json 2>/dev/null || echo '{}'
}

# ─── Extract SQL year-version from image offer string ─────────────────────────
# e.g. "SQL2019-WS2019" → "2019",  "SQL2022-WS2022" → "2022"
parse_sql_version_from_offer() {
    local offer=$1
    local ver
    ver=$(echo "$offer" | grep -oE 'SQL[0-9]{4}' | grep -oE '[0-9]{4}' || true)
    echo "${ver:-unknown}"
}

# ─── Find Log Analytics workspaces with the ChangeTracking solution ───────────
find_ct_workspace_resource_ids() {
    local sub_id=$1
    local result
    result=$(az resource list \
        --subscription "$sub_id" \
        --resource-type "Microsoft.OperationsManagement/solutions" \
        --query "[?contains(name,'ChangeTracking')].properties.workspaceResourceId" \
        -o json 2>&1) || {
        warn "  az resource list failed: $result"
        echo "[]"
        return 0
    }
    # If the result is an empty array or null, also try the legacy solution name
    if [[ "$(echo "$result" | jq 'length')" -eq 0 ]]; then
        dbg "  No 'ChangeTracking' solution found, trying 'changeTracking' (case variant)"
        result=$(az resource list \
            --subscription "$sub_id" \
            --resource-type "Microsoft.OperationsManagement/solutions" \
            --query "[?contains(to_string(name),'hangeTracking')].properties.workspaceResourceId" \
            -o json 2>/dev/null || echo "[]")
    fi
    echo "$result"
}

# ─── Resolve workspace resource ID → customer ID (GUID) ───────────────────────
ws_resource_id_to_customer_id() {
    local rid=$1
    local ws_name ws_rg ws_sub
    ws_name=$(echo "$rid" | awk -F'/' '{print $NF}')
    ws_rg=$(echo "$rid" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="resourceGroups") print $(i+1)}')
    ws_sub=$(echo "$rid" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="subscriptions") print $(i+1)}')
    local result
    result=$(az monitor log-analytics workspace show \
        --workspace-name "$ws_name" \
        --resource-group "$ws_rg" \
        ${ws_sub:+--subscription "$ws_sub"} \
        --query 'customerId' -o tsv 2>&1) || {
        warn "  Could not resolve workspace customer ID for: $ws_name ($result)"
        return 0
    }
    echo "$result" | tr -d '\r'
}

# ─── Normalise az monitor log-analytics query output ──────────────────────────
# Older CLI versions return a flat JSON array; newer versions return
# { "tables": [{ "columns": [...], "rows": [...] }] }.  This handles both.
normalize_la_output() {
    local raw=$1
    if jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1; then
        echo "$raw"
    elif jq -e '.tables' <<<"$raw" >/dev/null 2>&1; then
        jq '
            .tables[0]
            | . as $t
            | [ $t.rows[]
                | . as $row
                | [ range($t.columns | length)
                    | { key: $t.columns[.].name, value: $row[.] }
                  ] | from_entries
              ]
        ' <<<"$raw"
    else
        echo "[]"
    fi
}

# ─── Query MSSQL instances from Change Tracking Inventory ────────────────────
# Sources both WindowsServices (MSSQL* service names) and Software Inventory
# (Microsoft SQL Server entries) so either CT configuration returns results.
# $1 = workspace customer ID
# $2 = optional KQL-safe comma-separated quoted computer names to scope the
#      query (e.g. '"vm-sql-01","vm-sql-02"').  Empty = no scope filter.
query_mssql_services() {
    local ws_id=$1
    local computers=${2:-""}

    # Optional per-computer scope injected into both let-blocks
    local computer_where=""
    [[ -n "$computers" ]] && computer_where="
| where Computer in~ ($computers)"

    # Windows Services matched by service short name (_svcName):
    #   MSSQL*              — SQL Server Database Engine (default + named instances)
    #   MsDtsServer*        — SQL Server Integration Services (SSIS)
    #   SQLServerReportingServices — SSRS 2017+
    #   ReportServer / ReportServer$* — SSRS 2016 and earlier
    # Display-name fallback catches any of the above when the service-name
    # column is empty (CT agent schema variant).
    # The service short name may live in SoftwareName, Name, or ServiceName
    # depending on the CT agent version — coalesce across all candidates first.
    # Software Inventory: "Microsoft SQL Server <year>" or "SQL Server"
    local kql
    kql='let svc = ConfigurationData
| where ConfigDataType == "WindowsServices"'"${computer_where}"'
| extend _svcName = coalesce(
    column_ifexists("SoftwareName", ""),
    column_ifexists("Name", ""),
    column_ifexists("ServiceName", ""),
    "")
| where _svcName startswith "MSSQL"
    or _svcName startswith "MsDtsServer"
    or _svcName =~ "SQLServerReportingServices"
    or _svcName startswith "ReportServer"
    or column_ifexists("CurrentServiceName", "") contains "SQL Server"
    or column_ifexists("ServiceDisplayName", "") contains "SQL Server"
| extend InstanceName = coalesce(
    _svcName,
    column_ifexists("CurrentServiceName", ""),
    column_ifexists("ServiceDisplayName", ""),
    "unknown")
| summarize arg_max(TimeGenerated, *) by Computer, InstanceName
| project Computer,
          InstanceName,
          Source        = "WindowsService",
          DisplayName   = coalesce(
              column_ifexists("CurrentServiceName", ""),
              column_ifexists("ServiceDisplayName", ""),
              InstanceName),
          State         = coalesce(
              column_ifexists("SvcState", ""),
              column_ifexists("ServiceState", ""),
              "unknown"),
          StartupType   = coalesce(
              column_ifexists("SvcStartupType", ""),
              column_ifexists("ServiceStartupType", ""),
              "unknown"),
          ServiceAccount= coalesce(
              column_ifexists("SvcAccount", ""),
              column_ifexists("ServiceAccount", ""),
              "unknown"),
          LastSeen      = strcat(format_datetime(TimeGenerated,"yyyy-MM-dd HH:mm"), " UTC");
let inv = ConfigurationData
| where ConfigDataType == "Software"'"${computer_where}"'
| where SoftwareName contains "SQL Server"
| summarize arg_max(TimeGenerated, *) by Computer, SoftwareName
| project Computer,
          InstanceName  = SoftwareName,
          Source        = "SoftwareInventory",
          DisplayName   = strcat(SoftwareName, " v", column_ifexists("SoftwareVersion", "")),
          State         = "Installed",
          StartupType   = "N/A",
          ServiceAccount= "N/A",
          LastSeen      = strcat(format_datetime(TimeGenerated,"yyyy-MM-dd HH:mm"), " UTC");
union svc, inv
| sort by Computer asc, Source asc, InstanceName asc'

    dbg "  Workspace: $ws_id"
    [[ -n "$computers" ]] && dbg "  Scoped to computers: $computers"
    dbg "  KQL query:"
    while IFS= read -r line; do dbg "    $line"; done <<<"$kql"

    local raw
    raw=$(az monitor log-analytics query \
        --workspace "$ws_id" \
        --analytics-query "$kql" \
        -o json 2>&1) || {
        warn "  Log Analytics query failed for workspace $ws_id: $raw"
        echo "[]"
        return 0
    }
    normalize_la_output "$raw"
}

# ─── Print VM results ─────────────────────────────────────────────────────────
print_vm_table() {
    local data=$1
    local h="%-22s %-28s %-20s %-14s %-26s %-22s %-12s %-12s %-14s\n"
    printf "${BOLD}${h}${NC}" \
        "SUBSCRIPTION" "VM NAME" "RESOURCE GROUP" "LOCATION" \
        "VM SIZE" "OS IMAGE SKU" "SQL SKU" "SQL VERSION" "LICENSE"
    printf '%0.s─' {1..180}; echo
    jq -r '.[] |
        [ .subscriptionName, .vmName, .resourceGroup, .location,
          .vmSize, .imageSku, .sqlSku, .sqlVersion, .sqlLicense ] | @tsv' \
        <<<"$data" \
    | while IFS=$'\t' read -r sub n rg loc sz osk ssk sv lic; do
        printf "$h" "$sub" "$n" "$rg" "$loc" "$sz" "$osk" "$ssk" "$sv" "$lic"
    done
}

print_vm_csv() {
    local data=$1
    echo "Subscription Name,Subscription ID,VM Name,Resource Group,Location,VM Size,OS Image SKU,SQL SKU,SQL Offer,SQL Version,License Type"
    jq -r '.[] |
        [ .subscriptionName, .subscriptionId, .vmName, .resourceGroup,
          .location, .vmSize, .imageSku, .sqlSku, .sqlOffer, .sqlVersion,
          .sqlLicense ] | @csv' \
        <<<"$data"
}

# ─── Print inventory results ──────────────────────────────────────────────────
print_inv_table() {
    local data=$1
    local h="%-22s %-28s %-18s %-20s %-36s %-12s %-22s\n"
    printf "${BOLD}${h}${NC}" \
        "SUBSCRIPTION" "COMPUTER" "SOURCE" "INSTANCE (SVC NAME)" "DISPLAY NAME" "STATE" "LAST SEEN"
    printf '%0.s─' {1..165}; echo
    jq -r '.[] |
        [ .subscriptionName, .Computer, (.Source // "unknown"), .InstanceName,
          .DisplayName, .State, .LastSeen ] | @tsv' \
        <<<"$data" \
    | while IFS=$'\t' read -r sub comp src inst disp state last; do
        printf "$h" "$sub" "$comp" "$src" "$inst" "$disp" "$state" "$last"
    done
}

print_inv_csv() {
    local data=$1
    echo "Subscription Name,Subscription ID,Computer,Source,Instance Name,Display Name,State,Startup Type,Service Account,Last Seen"
    jq -r '.[] |
        [ .subscriptionName, .subscriptionId, .Computer, (.Source // "unknown"),
          .InstanceName, .DisplayName, .State, .StartupType, .ServiceAccount, .LastSeen ] | @csv' \
        <<<"$data"
}

# ─── Process one subscription: collect SQL VMs ────────────────────────────────
process_subscription_vms() {
    local sub_id=$1 sub_name=$2 all_vms_ref=$3

    log "  Fetching SQL VMs in: ${BOLD}${sub_name}${NC} [${sub_id}]" >&2

    local raw_vms
    raw_vms=$(fetch_sql_vms "$sub_id")
    local vm_count
    vm_count=$(jq 'length' <<<"$raw_vms")

    if [[ "$vm_count" -eq 0 ]]; then
        warn "  No SQL VMs found in $sub_name"
        return 0
    fi
    ok "  Found ${vm_count} SQL VM(s) – fetching compute details..."

    local vm_idx=0
    # Use fd 3 for the VM stream so that az commands inside the loop
    # cannot accidentally consume data from the loop's read source.
    while IFS= read -r vm <&3; do
        (( vm_idx++ )) || true
        local name rg loc sql_sku sql_offer sql_license
        name=$(jq -r '.name'         <<<"$vm" || true)
        rg=$(jq -r   '.resourceGroup' <<<"$vm" || true)
        loc=$(jq -r  '.location'      <<<"$vm" || true)
        # Support both top-level fields (newer CLI) and nested .properties (older CLI)
        sql_sku=$(jq -r     '(.properties.sqlImageSku       // .sqlImageSku)       // "unknown"' <<<"$vm" || true)
        sql_offer=$(jq -r   '(.properties.sqlImageOffer     // .sqlImageOffer)     // ""'        <<<"$vm" || true)
        sql_license=$(jq -r '(.properties.sqlServerLicenseType // .sqlServerLicenseType) // "unknown"' <<<"$vm" || true)

        [[ -z "$name" || "$name" == "null" ]] && continue

        progress_bar "$vm_idx" "$vm_count" "$name"
        dbg "    [$$] VM ${vm_idx}/${vm_count}: ${name} (${rg})"

        local compute vm_size img_sku
        compute=$(fetch_vm_compute "$name" "$rg")
        vm_size=$(jq -r '.vmSize   // "unknown"' <<<"$compute" || true)
        img_sku=$(jq -r '.imageSku // "unknown"' <<<"$compute" || true)

        local sql_version
        sql_version=$(parse_sql_version_from_offer "$sql_offer")

        local entry
        entry=$(jq -cn \
            --arg subId        "$sub_id"       \
            --arg subName      "$sub_name"     \
            --arg vmName       "$name"         \
            --arg rg           "$rg"           \
            --arg location     "$loc"          \
            --arg vmSize       "$vm_size"      \
            --arg imageSku     "$img_sku"      \
            --arg sqlSku       "$sql_sku"      \
            --arg sqlOffer     "$sql_offer"    \
            --arg sqlVersion   "$sql_version"  \
            --arg sqlLicense   "$sql_license"  \
            '{ subscriptionId:$subId, subscriptionName:$subName,
               vmName:$vmName, resourceGroup:$rg, location:$location,
               vmSize:$vmSize, imageSku:$imageSku,
               sqlSku:$sqlSku, sqlOffer:$sqlOffer, sqlVersion:$sqlVersion,
               sqlLicense:$sqlLicense }')

        printf '%s\n' "$entry"
    done 3< <(jq -c '.[]' <<<"$raw_vms")
}

# ─── Process one subscription: collect MSSQL inventory ───────────────────────
# $3 = optional computer filter (KQL comma-separated quoted names)
process_subscription_inventory() {
    local sub_id=$1 sub_name=$2 computer_filter=${3:-""}

    local workspaces=()

    if [[ -n "$WORKSPACE_ID" ]]; then
        # Global workspace override – don't re-resolve per subscription
        workspaces+=("$WORKSPACE_ID")
    else
        dbg "  Finding Change Tracking workspaces in: $sub_name"
        local ct_rids
        ct_rids=$(find_ct_workspace_resource_ids "$sub_id")
        local ws_count
        ws_count=$(jq 'length' <<<"$ct_rids")
        if [[ "$ws_count" -eq 0 ]]; then
            warn "  No Change Tracking workspaces found in $sub_name"
            return 0
        fi
        dbg "  Found $ws_count Change Tracking workspace(s)"
        while IFS= read -r rid; do
            local cid
            cid=$(ws_resource_id_to_customer_id "$rid")
            [[ -n "$cid" ]] && workspaces+=("$cid")
        done < <(jq -r '.[]' <<<"$ct_rids")
    fi

    [[ ${#workspaces[@]} -eq 0 ]] && {
        warn "  Could not resolve any queryable workspaces in $sub_name"
        return 0
    }

    for ws in "${workspaces[@]}"; do
        log "  Querying workspace ${ws} (${sub_name})"
        local inst
        inst=$(query_mssql_services "$ws" "$computer_filter")
        local cnt
        cnt=$(jq 'length' <<<"$inst")
        ok "  $cnt MSSQL instance(s) found"

        # Inject subscription fields — compact output (one JSON array per line)
        jq -c --arg sid "$sub_id" --arg sname "$sub_name" \
            '[.[] | . + { subscriptionId: $sid, subscriptionName: $sname }]' \
            <<<"$inst"
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    # ── Parse arguments ────────────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--subscription)
                # Accept comma-separated list or single value; repeatable
                IFS=',' read -ra _subs <<< "$2"
                SUBSCRIPTIONS+=("${_subs[@]}")
                shift 2 ;;
            -f|--subscriptions-file) SUBSCRIPTIONS_FILE="$2"; shift 2 ;;
            -g|--resource-group)     RESOURCE_GROUP="$2";     shift 2 ;;
            -w|--workspace)          WORKSPACE_ID="$2";       shift 2 ;;
            -o|--output)             OUTPUT_FORMAT="$2";      shift 2 ;;
            --vms-file)              VMS_OUTPUT_FILE="$2";    shift 2 ;;
            --inv-file)              INV_OUTPUT_FILE="$2";    shift 2 ;;
            --svc-file)              SVC_OUTPUT_FILE="$2";    shift 2 ;;
            --sw-file)               SW_OUTPUT_FILE="$2";     shift 2 ;;
            -i|--interactive)        INTERACTIVE=true;        shift   ;;
            --skip-inventory)        SKIP_INVENTORY=true;     shift   ;;
            -v|--verbose)            VERBOSE=true;            shift   ;;
            -h|--help)               usage; exit 0            ;;
            *) die "Unknown option: $1  (use -h for help)" ;;
        esac
    done

    check_prereqs

    log "${SCRIPT_NAME} v${VERSION}  (PID $$)"

    $INTERACTIVE && interactive_login_and_select

    # Load subscriptions from file if provided
    [[ -n "$SUBSCRIPTIONS_FILE" ]] && load_subscriptions_file "$SUBSCRIPTIONS_FILE"

    # Default to the currently active account if nothing specified
    if [[ ${#SUBSCRIPTIONS[@]} -eq 0 ]]; then
        local current_sub
        current_sub=$(az account show --query 'id' -o tsv | tr -d '\r')
        SUBSCRIPTIONS+=("$current_sub")
    fi

    log "Scanning ${#SUBSCRIPTIONS[@]} subscription(s)..."

    # ── Single pass: collect VMs then scoped inventory per subscription ────────
    local all_vms="[]"
    local all_instances="[]"
    local sub
    for sub in "${SUBSCRIPTIONS[@]}"; do
        az account set --subscription "$sub" 2>/dev/null || {
            warn "Cannot access subscription: $sub – skipping"
            continue
        }
        local sub_name
        sub_name=$(az account show --query 'name' -o tsv 2>/dev/null | tr -d '\r' || echo "$sub")

        # ── VMs ──────────────────────────────────────────────────────────────
        local vm_entries
        vm_entries=$(process_subscription_vms "$sub" "$sub_name" "")
        if [[ -n "$vm_entries" ]]; then
            all_vms=$(printf '%s\n%s' "$all_vms" \
                "$(echo "$vm_entries" | jq -s '.')" \
                | jq -s 'add // []')
        fi

        $SKIP_INVENTORY && continue

        # ── Inventory scoped to VMs found in this subscription ────────────────
        # Build KQL-safe list of quoted VM names to use as Computer filter.
        # This prevents querying the entire workspace and returning data from
        # unrelated machines.
        local computer_filter=""
        if [[ -n "$vm_entries" ]]; then
            computer_filter=$(echo "$vm_entries" \
                | jq -rs '[.[].vmName] | map("\"" + . + "\"") | join(",")' \
                2>/dev/null || true)
        fi

        if [[ -z "$computer_filter" ]]; then
            dbg "  No VMs found in $sub_name — skipping inventory query"
            continue
        fi

        dbg "  Computer filter: $computer_filter"

        # Capture all workspace batches at once (each is a compact JSON array on
        # its own line) then merge into all_instances in a single jq pass.
        local inv_output
        inv_output=$(process_subscription_inventory "$sub" "$sub_name" "$computer_filter")
        if [[ -n "$inv_output" ]]; then
            all_instances=$(printf '%s\n%s' "$all_instances" "$inv_output" \
                | jq -s 'add // []')
        fi
    done

    # ── Print VM results ──────────────────────────────────────────────────────
    printf "\n${BOLD}═══ SQL Virtual Machines ═══════════════════════════════════════${NC}\n\n" >&2
    if [[ $(jq 'length' <<<"$all_vms") -eq 0 ]]; then
        warn "No SQL VMs found across all subscriptions."
    else
        local vms_dest="${VMS_OUTPUT_FILE:-/dev/stdout}"
        [[ -n "$VMS_OUTPUT_FILE" ]] && log "Writing SQL VM results → ${VMS_OUTPUT_FILE}"
        case "$OUTPUT_FORMAT" in
            json) jq . <<<"$all_vms"        > "$vms_dest" ;;
            csv)  print_vm_csv "$all_vms"   > "$vms_dest" ;;
            *)    print_vm_table "$all_vms" > "$vms_dest" ;;
        esac
        [[ -n "$VMS_OUTPUT_FILE" ]] && ok "SQL VM results written to: ${VMS_OUTPUT_FILE}"
    fi

    $SKIP_INVENTORY && return 0

    # ── Print inventory results ───────────────────────────────────────────────
    printf "\n${BOLD}═══ Change Tracking – SQL Server Inventory ═════════════════════${NC}\n\n" >&2
    if [[ $(jq 'length' <<<"$all_instances") -eq 0 ]]; then
        warn "No instances found in Change Tracking inventory."
        warn "Ensure VMs are onboarded to Change Tracking and collection has run."
        return 0
    fi

    # Helper: write a data block to its destination
    _write_inv() {
        local data=$1 dest=$2
        case "$OUTPUT_FORMAT" in
            json) jq . <<<"$data"         > "$dest" ;;
            csv)  print_inv_csv "$data"   > "$dest" ;;
            *)    print_inv_table "$data" > "$dest" ;;
        esac
    }

    if [[ -n "$SVC_OUTPUT_FILE" || -n "$SW_OUTPUT_FILE" ]]; then
        # ── Split mode: Windows Services and Software Inventory separately ──────
        local svc_data sw_data
        svc_data=$(jq '[.[] | select(.Source == "WindowsService")]'   <<<"$all_instances")
        sw_data=$(jq  '[.[] | select(.Source == "SoftwareInventory")]' <<<"$all_instances")

        printf "${BOLD}── Windows Services ────────────────────────────────────────────${NC}\n\n" >&2
        local svc_dest="${SVC_OUTPUT_FILE:-/dev/stdout}"
        [[ -n "$SVC_OUTPUT_FILE" ]] && log "Writing Windows Services → ${SVC_OUTPUT_FILE}"
        _write_inv "$svc_data" "$svc_dest"
        [[ -n "$SVC_OUTPUT_FILE" ]] && ok "Windows Services written to: ${SVC_OUTPUT_FILE}"

        printf "\n${BOLD}── Software Inventory ──────────────────────────────────────────${NC}\n\n" >&2
        local sw_dest="${SW_OUTPUT_FILE:-/dev/stdout}"
        [[ -n "$SW_OUTPUT_FILE" ]] && log "Writing Software Inventory → ${SW_OUTPUT_FILE}"
        _write_inv "$sw_data" "$sw_dest"
        [[ -n "$SW_OUTPUT_FILE" ]] && ok "Software Inventory written to: ${SW_OUTPUT_FILE}"

        # Also write combined if --inv-file explicitly requested alongside split
        if [[ -n "$INV_OUTPUT_FILE" ]]; then
            log "Writing combined inventory → ${INV_OUTPUT_FILE}"
            _write_inv "$all_instances" "$INV_OUTPUT_FILE"
            ok "Combined inventory written to: ${INV_OUTPUT_FILE}"
        fi
    else
        # ── Standard mode: combined output ────────────────────────────────────
        local inv_dest="${INV_OUTPUT_FILE:-/dev/stdout}"
        [[ -n "$INV_OUTPUT_FILE" ]] && log "Writing inventory results → ${INV_OUTPUT_FILE}"
        _write_inv "$all_instances" "$inv_dest"
        [[ -n "$INV_OUTPUT_FILE" ]] && ok "Inventory results written to: ${INV_OUTPUT_FILE}"
    fi
}

main "$@"
