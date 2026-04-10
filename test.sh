#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/test.log"

_main() {
    # Source shared helpers and variables
    source "$SCRIPT_DIR/tests/common.sh"

    # Source all test files (each appends to ALL_TESTS)
    for f in "$SCRIPT_DIR"/tests/test_*.sh; do
        source "$f"
    done

    # --- CLI ---

    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        usage
        exit 0
    fi

    TESTS_TO_RUN=("${@}")
    if [ ${#TESTS_TO_RUN[@]} -eq 0 ]; then
        TESTS_TO_RUN=("${ALL_TESTS[@]}")
    fi

    # Validate test names
    for t in "${TESTS_TO_RUN[@]}"; do
        if ! declare -f "$t" >/dev/null 2>&1; then
            echo "Unknown test: $t"
            echo ""
            usage
            exit 1
        fi
    done

    trap cleanup EXIT
    setup

    echo ""
    echo "=== Running ${#TESTS_TO_RUN[@]} test(s) ==="
    echo ""

    FAILED=0
    PASSED=0

    for t in "${TESTS_TO_RUN[@]}"; do
        echo "--- $t ---"
        test_setup
        if $t; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
        test_teardown
    done

    echo ""
    echo "=== Results: $PASSED passed, $FAILED failed ==="

    if [ "$FAILED" -gt 0 ]; then
        exit 1
    fi
}

_main "$@" 2>&1 | tee "$LOG_FILE"
