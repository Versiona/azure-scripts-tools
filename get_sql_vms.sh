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
readonly VERSION="1.3.0"

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

${BOLD}SUBSCRIPTIONS FILE FORMAT${NC}
  # This is a comment
  00000000-0000-0000-0000-000000000001
  00000000-0000-0000-0000-000000000002

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

# ─── Fetch all SQL VMs in the currently active subscription ───────────────────
fetch_sql_vms() {
    local args=()
    [[ -n "$RESOURCE_GROUP" ]] && args+=(--resource-group "$RESOURCE_GROUP")
    dbg "  az sql vm list ${args[*]:-}"
    az sql vm list "${args[@]}" -o json 2>/dev/null || echo "[]"
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
    az resource list \
        --resource-type "Microsoft.OperationsManagement/solutions" \
        --query "[?contains(name,'ChangeTracking')].properties.workspaceResourceId" \
        -o json 2>/dev/null || echo "[]"
}

# ─── Resolve workspace resource ID → customer ID (GUID) ───────────────────────
ws_resource_id_to_customer_id() {
    local rid=$1
    local ws_name ws_rg
    ws_name=$(echo "$rid" | awk -F'/' '{print $NF}')
    ws_rg=$(echo "$rid" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="resourceGroups") print $(i+1)}')
    az monitor log-analytics workspace show \
        --workspace-name "$ws_name" \
        --resource-group "$ws_rg" \
        --query 'customerId' -o tsv 2>/dev/null | tr -d '\r' || true
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

# ─── Query MSSQL Windows services from Change Tracking ────────────────────────
# MSSQLSERVER  = default instance
# MSSQL$<name> = named instance
query_mssql_services() {
    local ws_id=$1

    local kql='ConfigurationData | where ConfigDataType == "WindowsServices" | where SoftwareName startswith "MSSQL" | summarize arg_max(TimeGenerated, *) by Computer, SoftwareName | project Computer, InstanceName=SoftwareName, DisplayName=CurrentServiceName, State=SvcState, StartupType=SvcStartupType, ServiceAccount=SvcAccount, LastSeen=format_datetime(TimeGenerated,"yyyy-MM-dd HH:mm UTC") | sort by Computer asc, InstanceName asc'

    local raw
    raw=$(az monitor log-analytics query \
        --workspace "$ws_id" \
        --analytics-query "$kql" \
        -o json 2>/dev/null || echo "[]")
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
    local h="%-22s %-28s %-20s %-38s %-10s %-22s\n"
    printf "${BOLD}${h}${NC}" \
        "SUBSCRIPTION" "COMPUTER" "INSTANCE (SVC NAME)" "DISPLAY NAME" "STATE" "LAST SEEN"
    printf '%0.s─' {1..147}; echo
    jq -r '.[] |
        [ .subscriptionName, .Computer, .InstanceName,
          .DisplayName, .State, .LastSeen ] | @tsv' \
        <<<"$data" \
    | while IFS=$'\t' read -r sub comp inst disp state last; do
        printf "$h" "$sub" "$comp" "$inst" "$disp" "$state" "$last"
    done
}

print_inv_csv() {
    local data=$1
    echo "Subscription Name,Subscription ID,Computer,Instance Name,Display Name,State,Startup Type,Service Account,Last Seen"
    jq -r '.[] |
        [ .subscriptionName, .subscriptionId, .Computer, .InstanceName,
          .DisplayName, .State, .StartupType, .ServiceAccount, .LastSeen ] | @csv' \
        <<<"$data"
}

# ─── Process one subscription: collect SQL VMs ────────────────────────────────
process_subscription_vms() {
    local sub_id=$1 sub_name=$2 all_vms_ref=$3

    log "  Fetching SQL VMs in: ${BOLD}${sub_name}${NC} [${sub_id}]" >&2

    local raw_vms
    raw_vms=$(fetch_sql_vms)
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
process_subscription_inventory() {
    local sub_id=$1 sub_name=$2

    local workspaces=()

    if [[ -n "$WORKSPACE_ID" ]]; then
        # Global workspace override – don't re-resolve per subscription
        workspaces+=("$WORKSPACE_ID")
    else
        dbg "  Finding Change Tracking workspaces in: $sub_name"
        local ct_rids
        ct_rids=$(find_ct_workspace_resource_ids)
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
        inst=$(query_mssql_services "$ws")
        local cnt
        cnt=$(jq 'length' <<<"$inst")
        ok "  $cnt MSSQL instance(s) found"

        # Inject subscription fields into each result row
        jq --arg sid "$sub_id" --arg sname "$sub_name" \
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
            -i|--interactive)        INTERACTIVE=true;        shift   ;;
            --skip-inventory)        SKIP_INVENTORY=true;     shift   ;;
            -v|--verbose)            VERBOSE=true;            shift   ;;
            -h|--help)               usage; exit 0            ;;
            *) die "Unknown option: $1  (use -h for help)" ;;
        esac
    done

    check_prereqs

    log "Script PID: $$"

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

    # ── Collect SQL VMs across all subscriptions ───────────────────────────────
    printf "\n${BOLD}═══ SQL Virtual Machines ═══════════════════════════════════════${NC}\n\n"

    local all_vms="[]"
    local sub
    for sub in "${SUBSCRIPTIONS[@]}"; do
        az account set --subscription "$sub" 2>/dev/null || {
            warn "Cannot access subscription: $sub – skipping"
            continue
        }
        local sub_name
        sub_name=$(az account show --query 'name' -o tsv 2>/dev/null | tr -d '\r' || echo "$sub")

        # Collect VM entries as newline-separated JSON objects, then append
        local vm_entries
        vm_entries=$(process_subscription_vms "$sub" "$sub_name" "")
        if [[ -n "$vm_entries" ]]; then
            all_vms=$(printf '%s\n%s' "$all_vms" \
                "$(echo "$vm_entries" | jq -s '.')" \
                | jq -s 'add // []')
        fi
    done

    if [[ $(jq 'length' <<<"$all_vms") -eq 0 ]]; then
        warn "No SQL VMs found across all subscriptions."
    else
        case "$OUTPUT_FORMAT" in
            json) jq . <<<"$all_vms"        ;;
            csv)  print_vm_csv "$all_vms"   ;;
            *)    print_vm_table "$all_vms" ;;
        esac
    fi

    # ── Change Tracking inventory across all subscriptions ────────────────────
    $SKIP_INVENTORY && return 0

    printf "\n${BOLD}═══ Change Tracking – Running MSSQL Instances ══════════════════${NC}\n\n"

    local all_instances="[]"
    for sub in "${SUBSCRIPTIONS[@]}"; do
        az account set --subscription "$sub" 2>/dev/null || continue
        local sub_name
        sub_name=$(az account show --query 'name' -o tsv 2>/dev/null | tr -d '\r' || echo "$sub")

        while IFS= read -r batch; do
            [[ -z "$batch" ]] && continue
            all_instances=$(printf '%s\n%s' "$all_instances" "$batch" \
                | jq -s 'add // []')
        done < <(process_subscription_inventory "$sub" "$sub_name")
    done

    if [[ $(jq 'length' <<<"$all_instances") -eq 0 ]]; then
        warn "No MSSQL instances found in Change Tracking inventory."
        warn "Ensure VMs are onboarded to Change Tracking and collection has run."
        return 0
    fi

    case "$OUTPUT_FORMAT" in
        json) jq . <<<"$all_instances"        ;;
        csv)  print_inv_csv "$all_instances"  ;;
        *)    print_inv_table "$all_instances" ;;
    esac
}

main "$@"
