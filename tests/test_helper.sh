#!/usr/bin/env bash
# Minimal test helper — no external dependencies required.
# Source this file from each test script.

PASS=0
FAIL=0
_CURRENT_SUITE=""

suite() { _CURRENT_SUITE="$1"; printf "\n\033[1m%s\033[0m\n" "$1"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf "  \033[32m✓\033[0m %s\n" "$desc"
        (( PASS++ )) || true
    else
        printf "  \033[31m✗\033[0m %s\n" "$desc"
        printf "      expected: %s\n" "$expected"
        printf "      actual  : %s\n" "$actual"
        (( FAIL++ )) || true
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf "  \033[32m✓\033[0m %s\n" "$desc"
        (( PASS++ )) || true
    else
        printf "  \033[31m✗\033[0m %s\n" "$desc"
        printf "      expected to contain: %s\n" "$needle"
        printf "      actual             : %s\n" "$haystack"
        (( FAIL++ )) || true
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf "  \033[32m✓\033[0m %s\n" "$desc"
        (( PASS++ )) || true
    else
        printf "  \033[31m✗\033[0m %s\n" "$desc"
        printf "      expected NOT to contain: %s\n" "$needle"
        (( FAIL++ )) || true
    fi
}

assert_exit_zero() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  \033[32m✓\033[0m %s\n" "$desc"
        (( PASS++ )) || true
    else
        printf "  \033[31m✗\033[0m %s [exit $?]\n" "$desc"
        (( FAIL++ )) || true
    fi
}

assert_exit_nonzero() {
    local desc="$1"; shift
    if ! "$@" >/dev/null 2>&1; then
        printf "  \033[32m✓\033[0m %s\n" "$desc"
        (( PASS++ )) || true
    else
        printf "  \033[31m✗\033[0m %s (expected non-zero exit)\n" "$desc"
        (( FAIL++ )) || true
    fi
}

summary() {
    printf "\n\033[1mResults: %d passed, %d failed\033[0m\n" "$PASS" "$FAIL"
    [[ "$FAIL" -eq 0 ]]
}
