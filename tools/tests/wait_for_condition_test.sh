#!/usr/bin/env bash
# Tests for the waiting-loop helpers: duration_to_seconds() and
# wait_for_condition() in common_lib.sh, plus the optional wait budget on
# device_util::init().
#
# 'adb' is stubbed so a test can make the device appear on the Nth poll.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(dirname "${TESTS_DIR}")"
# shellcheck source=lib/test_common.sh
source "${TESTS_DIR}/lib/test_common.sh"

STUB_ROOT="$(mktemp -d)"
trap 'rm -rf "$STUB_ROOT"' EXIT

# --- Stubs -------------------------------------------------------------------
mkdir -p "$STUB_ROOT/bin"

# Identity of the pretend device. The serial is deliberately made up: nothing
# here talks to real hardware, the stubs below are the only 'adb', 'fastboot'
# and 'pontis' the code under test can see. The one requirement is that the
# serial handed to device_util::init matches what the stub reports for
# ro.serialno, which is why both sides read the same variable.
HW_SERIAL="FAKESERIAL0001"
ADB_ENDPOINT="localhost:35249"   # where the stub pretends the device is bridged
export MOCK_HW_SERIAL="$HW_SERIAL"
export MOCK_ADB_ENDPOINT="$ADB_ENDPOINT"

cat > "$STUB_ROOT/bin/pontis" <<'STUB'
#!/usr/bin/env bash
[[ -n "${MOCK_PONTIS_FILE:-}" ]] || exit 1
cat "$MOCK_PONTIS_FILE"
STUB

# 'adb devices' reports nothing until the attempt counter reaches
# MOCK_ADB_APPEAR_AT, which lets a test simulate a device coming back. The
# device it then reports is MOCK_ADB_ENDPOINT, answering MOCK_HW_SERIAL for
# ro.serialno.
cat > "$STUB_ROOT/bin/adb" <<'STUB'
#!/usr/bin/env bash
COUNTER="${MOCK_COUNTER_FILE:-/dev/null}"
if [[ "${1:-}" == "devices" ]]; then
    n=0
    [[ -s "$COUNTER" ]] && n=$(<"$COUNTER")
    n=$(( n + 1 ))
    echo "$n" > "$COUNTER"
    echo "List of devices attached"
    if (( n >= ${MOCK_ADB_APPEAR_AT:-1} )); then
        printf '%s\tdevice\n' "${MOCK_ADB_ENDPOINT:?}"
    fi
    exit 0
fi
if [[ "${1:-}" == "-s" && "${3:-}" == "shell" && "${4:-}" == "getprop" ]]; then
    if [[ "$2" == "${MOCK_ADB_ENDPOINT:?}" ]]; then
        case "${5:-}" in
            ro.serialno)      echo "${MOCK_HW_SERIAL:?}" ;;
            ro.product.board) echo "shiba" ;;
            *)                echo "" ;;
        esac
        exit 0
    fi
    exit 1
fi
exit 1
STUB

cat > "$STUB_ROOT/bin/fastboot" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "devices" ]] && exit 0
exit 1
STUB

chmod +x "$STUB_ROOT/bin"/*
export PATH="$STUB_ROOT/bin:$PATH"

# device_util.sh pulls in common_lib.sh, which is where the helpers live.
# shellcheck source=/dev/null
source "$TOOLS_DIR/lib/device_util.sh" 2>/dev/null || {
    echo "cannot source device_util.sh" >&2
    exit 1
}

section "duration_to_seconds"

check "a bare integer means seconds" "30"    "$(duration_to_seconds 30)"
check "'45s'"                        "45"    "$(duration_to_seconds 45s)"
check "'3m'"                         "180"   "$(duration_to_seconds 3m)"
check "'2h'"                         "7200"  "$(duration_to_seconds 2h)"
check "'1d'"                         "86400" "$(duration_to_seconds 1d)"
check "'0'"                          "0"     "$(duration_to_seconds 0)"
# '08' is the classic octal trap: without a base-10 forcing prefix the
# arithmetic would abort with 'value too great for base'.
check "leading zero '08m' is base 10" "480"  "$(duration_to_seconds 08m 2>/dev/null)"
check "leading zero '09s' is base 10" "9"    "$(duration_to_seconds 09s 2>/dev/null)"

for bad in "1.5m" "abc" "" "-5" "5x" "m" "5 m"; do
    duration_to_seconds "$bad" > /dev/null 2>&1
    check "rejects '$bad'" "1" "$?"
done

section "wait_for_condition"

wait_for_condition 10s 1s "always true" true > /dev/null 2>&1
check "immediate success returns 0" "0" "$?"

START=$(date +%s)
wait_for_condition 10s 1s "always true" true > /dev/null 2>&1
check_range "immediate success does not sleep" 0 1 "$(( $(date +%s) - START ))"

# Succeeds on the third attempt.
ATTEMPTS=0
function thrice() { (( ++ATTEMPTS >= 3 )); }
START=$(date +%s)
wait_for_condition 30s 1s "third time lucky" thrice > /dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "delayed success returns 0" "0" "$RC"
check "delayed success ran 3 attempts" "3" "$ATTEMPTS"
check_range "delayed success took about two intervals" 1 4 "$ELAPSED"

# Never succeeds: must give up at the budget, not one interval later.
START=$(date +%s)
wait_for_condition 5s 2s "never happens" false > /dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "an exhausted budget returns EXIT_TIMEOUT" "124" "$RC"
check_range "it does not overshoot the budget" 0 5 "$ELAPSED"

# A budget of 0 means exactly one attempt, no sleeping, and no scary log.
# Note: stdout goes to a file rather than $(...), because command substitution
# would run wait_for_condition in a subshell and the attempt counter would
# never make it back.
ATTEMPT_FILE="$STUB_ROOT/attempts"
: > "$ATTEMPT_FILE"
function counting_false() { echo x >> "$ATTEMPT_FILE"; return 1; }
START=$(date +%s)
wait_for_condition 0 5s "zero budget" counting_false > "$STUB_ROOT/zero.log" 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
OUT=$(<"$STUB_ROOT/zero.log")
check "a zero budget returns EXIT_TIMEOUT" "124" "$RC"
check "a zero budget runs exactly one attempt" "1" "$(wc -l < "$ATTEMPT_FILE")"
check_range "a zero budget does not sleep" 0 1 "$ELAPSED"
check "a zero budget stays quiet" "quiet" \
    "$([[ "$OUT" == *"Gave up after"* ]] && echo "logged: $OUT" || echo quiet)"

# The command must run in the current shell so it can set globals.
GLOBAL_CANARY=""
function sets_global() { GLOBAL_CANARY="touched"; return 0; }
wait_for_condition 5s 1s "canary" sets_global > /dev/null 2>&1
check "the command runs in the current shell" "touched" "$GLOBAL_CANARY"

# Arguments are passed through untouched, including ones with spaces.
function echo_args() { [[ "$1" == "a b" && "$2" == "c" ]]; }
wait_for_condition 5s 1s "args" echo_args "a b" "c" > /dev/null 2>&1
check "arguments with spaces survive" "0" "$?"

section "wait_for_condition: argument validation"

wait_for_condition 5s 0s "bad interval" true > /dev/null 2>&1
check "a zero interval is rejected" "1" "$?"
wait_for_condition "bogus" 1s "bad timeout" true > /dev/null 2>&1
check "an unparseable timeout is rejected" "1" "$?"
wait_for_condition 5s "bogus" "bad interval" true > /dev/null 2>&1
check "an unparseable interval is rejected" "1" "$?"
wait_for_condition 5s 1s "no command" > /dev/null 2>&1
check "a missing command is rejected" "1" "$?"
wait_for_condition "" 1s "empty timeout" true > /dev/null 2>&1
check "an empty timeout is rejected" "1" "$?"

section "device_util::init backward compatibility"

export MOCK_PONTIS_FILE="/dev/null"
export MOCK_COUNTER_FILE="$STUB_ROOT/counter"
DEFAULT_DEVICE_POLL_INTERVAL="1s"

# No second argument: must behave exactly as before, i.e. check once and fail
# immediately. This is what the existing callers rely on.
: > "$MOCK_COUNTER_FILE"
export MOCK_ADB_APPEAR_AT=9999   # never appears
START=$(date +%s)
device_util::init "$HW_SERIAL" > /dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "init without a budget returns 1" "1" "$RC"
check_range "init without a budget does not block" 0 1 "$ELAPSED"
check "init without a budget polls adb once" "1" "$(<"$MOCK_COUNTER_FILE")"

# Explicit '0' is the same thing.
: > "$MOCK_COUNTER_FILE"
device_util::init "$HW_SERIAL" "0" > /dev/null 2>&1
check "an explicit zero budget returns 1" "1" "$?"
check "an explicit zero budget polls adb once" "1" "$(<"$MOCK_COUNTER_FILE")"

section "device_util::init with a wait budget"

if slow_enabled; then
    # The device shows up on the fourth poll, well inside the budget.
    : > "$MOCK_COUNTER_FILE"
    export MOCK_ADB_APPEAR_AT=4
    START=$(date +%s)
    device_util::init "$HW_SERIAL" "30s" > /dev/null 2>&1
    RC=$?
    ELAPSED=$(( $(date +%s) - START ))
    check "init waits and then succeeds" "0" "$RC"
    check "init resolved the adb serial" "$ADB_ENDPOINT" "$(device_util::get_adb_serial)"
    check "init set mode ADB" "ADB" "$_DEVICE_UTIL_MODE"
    check "init set type PHYSICAL" "PHYSICAL" "$_DEVICE_UTIL_TYPE"
    check_range "init returned soon after the device appeared" 2 8 "$ELAPSED"

    # Device never shows up: fail at the budget, and report 1 rather than 124 so
    # the boolean contract every caller relies on is unchanged.
    : > "$MOCK_COUNTER_FILE"
    export MOCK_ADB_APPEAR_AT=9999
    START=$(date +%s)
    device_util::init "$HW_SERIAL" "4s" > /dev/null 2>&1
    RC=$?
    ELAPSED=$(( $(date +%s) - START ))
    check "init gives up with 1, not 124" "1" "$RC"
    check_range "init respects the budget" 3 7 "$ELAPSED"

    # A stale serial from an earlier successful init must not leak through.
    check "init cleared the previous adb serial" "" "$(device_util::get_adb_serial)"
else
    skip_test "init waits for a device inside its budget" "SKIP_SLOW"
    skip_test "init gives up at the budget" "SKIP_SLOW"
fi

# An invalid budget must fail closed rather than loop forever.
device_util::init "$HW_SERIAL" "banana" > /dev/null 2>&1
check "an invalid budget fails closed" "1" "$?"

# Empty serial still rejected.
device_util::init "" "30s" > /dev/null 2>&1
check "an empty serial is still rejected" "1" "$?"

section "strict mode"

: > "$MOCK_COUNTER_FILE"
# Write the inner script to a file: inlining it in 'bash -c "..."' made the
# nested quoting ambiguous and previously clobbered PATH, which hid coreutils.
cat > "$STUB_ROOT/strict.sh" <<EOF
set -euo pipefail
export PATH="$STUB_ROOT/bin:\$PATH"
export MOCK_PONTIS_FILE=/dev/null
export MOCK_COUNTER_FILE="$MOCK_COUNTER_FILE"
export MOCK_ADB_APPEAR_AT=2
export MOCK_HW_SERIAL="$HW_SERIAL"
export MOCK_ADB_ENDPOINT="$ADB_ENDPOINT"
source "$TOOLS_DIR/lib/device_util.sh"
DEFAULT_DEVICE_POLL_INTERVAL=1s
if ! device_util::init '$HW_SERIAL' '20s'; then echo 'INIT_FAILED'; exit 1; fi
echo "OK:\$(device_util::get_adb_serial)"
EOF
OUT=$(bash "$STUB_ROOT/strict.sh" 2>&1 | tail -n 1)
check "survives 'set -euo pipefail'" "OK:$ADB_ENDPOINT" "$OUT"

# A bare, successful call must not abort a 'set -e' caller. This regressed once:
# '(( attempt++ ))' returns status 1 on the first iteration because the old
# value is zero, which killed the script before the command even ran.
cat > "$STUB_ROOT/strict_bare.sh" <<EOF
set -euo pipefail
source "$TOOLS_DIR/common_lib.sh"
wait_for_condition 5s 1s "bare call" true
echo "REACHED_END"
EOF
OUT=$(bash "$STUB_ROOT/strict_bare.sh" 2>&1 | tail -n 1)
check "a bare successful call does not abort 'set -e'" "REACHED_END" "$OUT"

finish_tests
