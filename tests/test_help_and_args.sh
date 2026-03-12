#!/usr/bin/env bash
# Tests: help output and argument parsing behaviour.
# Does NOT require an Azure login or any Azure resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../get_sql_vms.sh"
# shellcheck source=test_helper.sh
source "$SCRIPT_DIR/test_helper.sh"

# ─── Help / usage ─────────────────────────────────────────────────────────────
suite "Help output"

HELP=$("$SCRIPT" --help 2>&1 || true)

assert_contains "-h shows version"          "v1."              "$HELP"
assert_contains "-h shows -s flag"          "-s, --subscription" "$HELP"
assert_contains "-h shows -f flag"          "-f, --subscriptions-file" "$HELP"
assert_contains "-h shows -i flag"          "-i, --interactive" "$HELP"
assert_contains "-h shows -o flag"          "-o, --output"     "$HELP"
assert_contains "-h shows --skip-inventory" "--skip-inventory"  "$HELP"
assert_contains "-h shows -v flag"          "-v, --verbose"    "$HELP"
assert_contains "-h shows -w flag"          "-w, --workspace"  "$HELP"
assert_contains "-h shows EXAMPLES section" "EXAMPLES"         "$HELP"
assert_contains "-h exit 0"                 ""                 "$(
    "$SCRIPT" --help >/dev/null 2>&1; echo $?
)"

# Short form also works
HELP_SHORT=$("$SCRIPT" -h 2>&1 || true)
assert_contains "-h and --help same output" "--interactive" "$HELP_SHORT"

# ─── Unknown flag ─────────────────────────────────────────────────────────────
suite "Unknown option handling"

OUTPUT=$("$SCRIPT" --bogus-flag 2>&1 || true)
assert_contains "unknown flag produces error message" "Unknown option" "$OUTPUT"
assert_contains "unknown flag suggests -h"            "-h"             "$OUTPUT"

# ─── Syntax check ─────────────────────────────────────────────────────────────
suite "Script syntax"

assert_exit_zero "bash -n passes" bash -n "$SCRIPT"

summary
