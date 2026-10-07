#!/usr/bin/env bash
# Shared harness for the plain-bash tests under kernel/tests/tools.
#
# Usage:
#   TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${TESTS_DIR}/lib/test_common.sh"
#   ...
#   finish_tests
#
# Note on frameworks: common_lib_test.sh uses shunit2. These helpers exist so
# the tests inherited from ad-hoc debugging sessions share one harness while
# they wait to be ported over. New tests should prefer shunit2.
#
# Environment:
#   SKIP_SLOW=1   Skip cases that spend real wall-clock time waiting for
#                 timeouts to fire. Everything else still runs.

TESTS_PASS=0
TESTS_FAIL=0
TESTS_SKIP=0

# section <title>
function section() {
    printf '\n== %s ==\n' "$1"
}

# check <name> <expected> <actual>
function check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS  %s\n' "$name"
        TESTS_PASS=$(( TESTS_PASS + 1 ))
    else
        printf '  FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' \
            "$name" "$expected" "$actual"
        TESTS_FAIL=$(( TESTS_FAIL + 1 ))
    fi
}

# check_range <name> <lo> <hi> <actual>   (inclusive, integers)
function check_range() {
    local name="$1" lo="$2" hi="$3" actual="$4"
    if (( actual >= lo && actual <= hi )); then
        printf '  PASS  %s (%ss)\n' "$name" "$actual"
        TESTS_PASS=$(( TESTS_PASS + 1 ))
    else
        printf '  FAIL  %s\n        expected: %s..%ss\n        actual:   %ss\n' \
            "$name" "$lo" "$hi" "$actual"
        TESTS_FAIL=$(( TESTS_FAIL + 1 ))
    fi
}

# skip_test <name> <reason>
function skip_test() {
    printf '  SKIP  %s (%s)\n' "$1" "$2"
    TESTS_SKIP=$(( TESTS_SKIP + 1 ))
}

# skip_file <reason> -- abandons the whole file without failing the run.
function skip_file() {
    printf 'SKIP: %s\n' "$1"
    exit 0
}

# slow_enabled -- false when SKIP_SLOW is set to anything non-empty.
function slow_enabled() {
    [[ -z "${SKIP_SLOW:-}" ]]
}

# require_cmd <cmd>... -- skip the file when a dependency is missing.
function require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || \
            skip_file "'${cmd}' is not available"
    done
}

# finish_tests -- prints the summary and returns non-zero on any failure.
function finish_tests() {
    printf '\n----------------------------------------\n'
    printf ' passed=%d failed=%d skipped=%d\n' \
        "$TESTS_PASS" "$TESTS_FAIL" "$TESTS_SKIP"
    printf -- '----------------------------------------\n'
    (( TESTS_FAIL == 0 ))
}
