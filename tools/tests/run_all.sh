#!/usr/bin/env bash
# Runs every *_test.sh in this directory and reports a combined result.
#
#   ./run_all.sh              run everything
#   SKIP_SLOW=1 ./run_all.sh  skip the cases that wait for real timeouts
#   ./run_all.sh device_util  run only tests whose name contains 'device_util'

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

FAILED=()
PASSED=()

for test_file in "${TESTS_DIR}"/*_test.sh; do
    [[ -e "$test_file" ]] || continue
    name="$(basename "$test_file")"
    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
        continue
    fi
    printf '\n########## %s ##########\n' "$name"
    if bash "$test_file"; then
        PASSED+=("$name")
    else
        FAILED+=("$name")
    fi
done

printf '\n==================================================\n'
printf ' %d passed, %d failed\n' "${#PASSED[@]}" "${#FAILED[@]}"
if (( ${#FAILED[@]} > 0 )); then
    printf ' failing suites:\n'
    printf '   %s\n' "${FAILED[@]}"
fi
printf '==================================================\n'

(( ${#FAILED[@]} == 0 ))
