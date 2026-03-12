#!/usr/bin/env bash
# Run all tests in this directory.
# Exit code: 0 if all pass, 1 if any fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERALL=0

for test_file in "$SCRIPT_DIR"/test_*.sh; do
    printf "\n\033[1;34m══ %s ══\033[0m\n" "$(basename "$test_file")"
    if bash "$test_file"; then
        : # pass
    else
        OVERALL=1
    fi
done

printf "\n"
if [[ "$OVERALL" -eq 0 ]]; then
    printf "\033[1;32mAll test suites passed.\033[0m\n"
else
    printf "\033[1;31mOne or more test suites FAILED.\033[0m\n"
fi

exit "$OVERALL"
