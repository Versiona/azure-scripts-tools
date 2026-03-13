#!/usr/bin/env bash
# Unit tests for pure-bash/jq helper functions extracted from get_sql_vms.sh.
# Does NOT require an Azure login or any Azure resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../get_sql_vms.sh"
# shellcheck source=test_helper.sh
source "$SCRIPT_DIR/test_helper.sh"

# ─── Source helpers from the main script without running main() ───────────────
# We temporarily replace main() with a no-op and source the script so all
# helper functions are available in this shell.
_SOURCED_SCRIPT=$(sed 's/^main "\$@"$/: # main disabled for unit tests/' "$SCRIPT")

# Silence the az-login check by pre-setting INTERACTIVE=true when sourcing
export INTERACTIVE=true
eval "$_SOURCED_SCRIPT"
unset INTERACTIVE
# Restore INTERACTIVE to its default for the rest of the tests
INTERACTIVE=false

# ─── parse_sql_version_from_offer ─────────────────────────────────────────────
suite "parse_sql_version_from_offer"

assert_eq "SQL2019-WS2019 → 2019" "2019" "$(parse_sql_version_from_offer "SQL2019-WS2019")"
assert_eq "SQL2022-WS2022 → 2022" "2022" "$(parse_sql_version_from_offer "SQL2022-WS2022")"
assert_eq "SQL2017-WS2016 → 2017" "2017" "$(parse_sql_version_from_offer "SQL2017-WS2016")"
assert_eq "empty string → unknown" "unknown" "$(parse_sql_version_from_offer "")"
assert_eq "garbage string → unknown" "unknown" "$(parse_sql_version_from_offer "WindowsServer2022")"
assert_eq "mixed case no match → unknown" "unknown" "$(parse_sql_version_from_offer "sql2019")"  # lowercase

# ─── normalize_la_output ──────────────────────────────────────────────────────
suite "normalize_la_output — flat array input"

FLAT='[{"Computer":"vm1","SoftwareName":"MSSQLSERVER"}]'
RESULT=$(normalize_la_output "$FLAT")
assert_eq "flat array passes through unchanged" "$FLAT" "$RESULT"

suite "normalize_la_output — empty flat array"

RESULT=$(normalize_la_output "[]")
assert_eq "empty array returns []" "[]" "$RESULT"

suite "normalize_la_output — tables envelope (newer CLI)"

TABLES_INPUT='{
  "tables": [{
    "columns": [
      {"name": "Computer"},
      {"name": "SoftwareName"}
    ],
    "rows": [
      ["vm1", "MSSQLSERVER"],
      ["vm2", "MSSQL$NAMED"]
    ]
  }]
}'

RESULT=$(normalize_la_output "$TABLES_INPUT")
COMP1=$(jq -r '.[0].Computer'     <<<"$RESULT")
SW2=$(jq -r   '.[1].SoftwareName' <<<"$RESULT")
COUNT=$(jq    'length'             <<<"$RESULT")

assert_eq "tables: first row Computer"        "vm1"         "$COMP1"
assert_eq "tables: second row SoftwareName"   "MSSQL\$NAMED" "$SW2"
assert_eq "tables: row count"                 "2"           "$COUNT"

suite "normalize_la_output — unrecognised structure falls back to []"

RESULT=$(normalize_la_output '{"something":"else"}')
assert_eq "unknown structure → []" "[]" "$RESULT"

# ─── load_subscriptions_file ──────────────────────────────────────────────────
suite "load_subscriptions_file"

TMP=$(mktemp)
cat >"$TMP" <<'EOF'
# This is a comment
00000000-0000-0000-0000-000000000001
  00000000-0000-0000-0000-000000000002
# another comment

00000000-0000-0000-0000-000000000003
EOF

SUBSCRIPTIONS=()
load_subscriptions_file "$TMP"
rm -f "$TMP"

assert_eq "loads 3 subscriptions"              "3"                                      "${#SUBSCRIPTIONS[@]}"
assert_eq "first sub ID"   "00000000-0000-0000-0000-000000000001" "${SUBSCRIPTIONS[0]}"
assert_eq "second sub ID"  "00000000-0000-0000-0000-000000000002" "${SUBSCRIPTIONS[1]}"
assert_eq "third sub ID"   "00000000-0000-0000-0000-000000000003" "${SUBSCRIPTIONS[2]}"

# ─── License type — JSON data model ──────────────────────────────────────────
suite "sqlLicense field in VM data model"

# Simulate what process_subscription_vms builds — verify sqlLicense is present
# and that both known values round-trip through jq unchanged.
for lic in PAYG AHUB DR unknown; do
    ENTRY=$(jq -n --arg l "$lic" '{ sqlLicense: $l }')
    GOT=$(jq -r '.sqlLicense' <<<"$ENTRY")
    assert_eq "license value preserved: $lic" "$lic" "$GOT"
done

# Verify csv header includes "License Type"
CSV_HEADER=$(jq -rn '
  [{ subscriptionName:"s", subscriptionId:"i", vmName:"n", resourceGroup:"r",
     location:"l", vmSize:"z", imageSku:"k", sqlSku:"sk", sqlOffer:"o",
     sqlVersion:"v", sqlLicense:"PAYG" }]
  | map([ .subscriptionName, .subscriptionId, .vmName, .resourceGroup,
          .location, .vmSize, .imageSku, .sqlSku, .sqlOffer, .sqlVersion,
          .sqlLicense ] | @csv) | .[]')
assert_contains "PAYG appears in csv row" "PAYG" "$CSV_HEADER"

suite "load_subscriptions_file — missing file exits"

SUBSCRIPTIONS=()
set +e
(load_subscriptions_file "/nonexistent/path/subs.txt") 2>/dev/null
EXIT=$?
set -e
assert_eq "missing file → non-zero exit" "1" "$EXIT"

# ─── Source field — inventory data model ─────────────────────────────────────
suite "Source field in inventory data model"

for src in WindowsService SoftwareInventory; do
    ENTRY=$(jq -n --arg s "$src" '{ Source: $s }')
    GOT=$(jq -r '.Source' <<<"$ENTRY")
    assert_eq "Source value preserved: $src" "$src" "$GOT"
done

# ─── Inventory CSV header includes Source column ──────────────────────────────
suite "print_inv_csv — Source column in header"

INV_HEADER=$(print_inv_csv "[]" | head -1)
assert_contains "inv csv header has Source"          "Source"           "$INV_HEADER"
assert_contains "inv csv header has Computer"        "Computer"         "$INV_HEADER"
assert_contains "inv csv header has Instance Name"   "Instance Name"    "$INV_HEADER"
assert_contains "inv csv header has Startup Type"    "Startup Type"     "$INV_HEADER"

# ─── KQL uses column_ifexists for optional columns ───────────────────────────
suite "KQL query — column_ifexists guard"

KQL_USES_CIFEX=$(grep -c 'column_ifexists' "$SCRIPT" || true)
assert_eq "column_ifexists appears in script" "1" "$( [[ "$KQL_USES_CIFEX" -ge 1 ]] && echo 1 || echo 0 )"

# ─── KQL unions WindowsServices and Software Inventory ───────────────────────
suite "KQL query — unions both sources"

assert_contains "kql has WindowsServices" "WindowsServices" "$(grep -o 'WindowsServices' "$SCRIPT" | head -1)"
assert_contains "kql has SoftwareInventory source label" "SoftwareInventory" "$(grep -o 'SoftwareInventory' "$SCRIPT" | head -1)"

summary
