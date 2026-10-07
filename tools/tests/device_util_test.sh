#!/usr/bin/env bash
# Tests for lib/device_util.sh and the device-detection helpers in
# flash_device.sh.
#
# Merged from two earlier ad-hoc scripts: one covering Pontis endpoint
# resolution, one covering the hang that happened when a Pontis-bridged device
# sat in Fastboot mode and 'fastboot getvar' never returned.
#
# Everything runs against stub 'pontis', 'adb' and 'fastboot' binaries injected
# onto PATH, so no real device is touched.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(dirname "${TESTS_DIR}")"
# shellcheck source=lib/test_common.sh
source "${TESTS_DIR}/lib/test_common.sh"

STUB_ROOT="$(mktemp -d)"
trap 'rm -rf "$STUB_ROOT"' EXIT

# --- Stub binaries -----------------------------------------------------------
# Behaviour is driven entirely by MOCK_* environment variables so each scenario
# can reshape the world without rewriting a stub.
#
#   MOCK_PONTIS_HEADER      header line for 'pontis devices' (default column order)
#   MOCK_PONTIS_ROWS        rows for 'pontis devices', '%b' escapes honoured
#   MOCK_ADB_DEVICES        rows for 'adb devices' (header is added by the stub)
#   MOCK_FB_DEVICES         rows for 'fastboot devices'
#   MOCK_ADB_HANG=1         make 'adb shell getprop' block forever
#   MOCK_FB_HANG=1          make 'fastboot getvar' block forever
#   MOCK_ADB_GOOD_ENDPOINT  the one adb endpoint that answers getprop
#   MOCK_FB_GOOD_ENDPOINT   the one fastboot endpoint that answers getvar
#   MOCK_HW_SERIAL          value returned for ro.serialno / any good getvar
#   MOCK_BOARD              value returned for ro.product.board
#   MOCK_PROP_<endpoint>    per-endpoint getprop answer, non-alnum chars as '_'
#   MOCK_FB_<endpoint>_<var>  per-endpoint getvar answer, same escaping
mkdir -p "$STUB_ROOT/bin"

cat > "$STUB_ROOT/bin/pontis" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "devices" ]] || exit 1
printf '%b' "${MOCK_PONTIS_HEADER:-BRIDGE\tID\tTYPE\tPORT\n}"
printf '%b' "${MOCK_PONTIS_ROWS:-}"
exit 0
STUB

cat > "$STUB_ROOT/bin/adb" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "devices" ]]; then
    echo "List of devices attached"
    printf '%b' "${MOCK_ADB_DEVICES:-}"
    exit 0
fi
# adb -s <serial> shell getprop <prop>
if [[ "${1:-}" == "-s" && "${3:-}" == "shell" && "${4:-}" == "getprop" ]]; then
    [[ "${MOCK_ADB_HANG:-0}" == "1" ]] && sleep 600
    serial="$2"
    prop="${5:-}"
    if [[ -n "${MOCK_ADB_GOOD_ENDPOINT:-}" && "$serial" == "${MOCK_ADB_GOOD_ENDPOINT}" ]]; then
        case "$prop" in
            ro.serialno)      echo "${MOCK_HW_SERIAL:-}" ;;
            ro.product.board) echo "${MOCK_BOARD:-shiba}" ;;
            *)                echo "" ;;
        esac
        exit 0
    fi
    key="MOCK_PROP_${serial//[^a-zA-Z0-9]/_}"
    if [[ -n "${!key:-}" ]]; then
        echo "${!key}"
        exit 0
    fi
    echo "adb: device '$serial' not found" >&2
    exit 1
fi
exit 0
STUB

cat > "$STUB_ROOT/bin/fastboot" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "devices" ]]; then
    printf '%b' "${MOCK_FB_DEVICES:-}"
    exit 0
fi
# fastboot -s <serial> getvar <var>
if [[ "${1:-}" == "-s" && "${3:-}" == "getvar" ]]; then
    [[ "${MOCK_FB_HANG:-0}" == "1" ]] && sleep 600
    serial="$2"
    var="${4:-}"
    if [[ -n "${MOCK_FB_GOOD_ENDPOINT:-}" && "$serial" == "${MOCK_FB_GOOD_ENDPOINT}" ]]; then
        echo "$var: ${MOCK_HW_SERIAL:-}" >&2
        echo "Finished. Total time: 0.001s" >&2
        exit 0
    fi
    key="MOCK_FB_${serial//[^a-zA-Z0-9]/_}_${var//[^a-zA-Z0-9]/_}"
    val="${!key:-}"
    if [[ -z "$val" ]]; then
        echo "getvar:$var FAILED (remote: 'unknown command')" >&2
        exit 1
    fi
    echo "$var: $val" >&2
    echo "Finished. Total time: 0.001s" >&2
    exit 0
fi
exit 0
STUB

chmod +x "$STUB_ROOT/bin"/*
export PATH="$STUB_ROOT/bin:$PATH"

# --- Libraries under test ----------------------------------------------------
# shellcheck source=/dev/null
source "$TOOLS_DIR/lib/device_util.sh" 2>/dev/null || {
    echo "cannot source device_util.sh" >&2
    exit 1
}

# flash_device.sh has top-level code, so extract just the functions under test.
awk '/^function is_device_in_adb\(\)/,/^function check_adb_status\(\)/' \
    "$TOOLS_DIR/flash_device.sh" | head -n -1 > "$STUB_ROOT/detect.sh"
# shellcheck source=/dev/null
source "$STUB_ROOT/detect.sh" || {
    echo "cannot source the extracted detection functions" >&2
    exit 1
}

# Deliberately made up; nothing here reaches a real device. Kept identical to
# the value in wait_for_condition_test.sh, where the reasoning is spelled out.
HW_SERIAL="FAKESERIAL0001"

# Clears every MOCK_* variable and the globals flash_device.sh works through.
function reset_mocks() {
    local var
    for var in $(compgen -v MOCK_ || true); do
        unset "$var"
    done
    SERIAL_NUMBER="$HW_SERIAL"
    ADB_SERIAL_NUMBER=""
    DEVICE_SERIAL_NUMBER=""
    FASTBOOT_SERIAL_NUMBER=""
    THROUGH_PONTIS=false
    export MOCK_HW_SERIAL="$HW_SERIAL"
}

reset_mocks

section "pontis_endpoint_for: TYPE column parsing"

# The original regression: TYPE carries a multi-word value.
export MOCK_PONTIS_ROWS="me@host\t${HW_SERIAL}\tADB with optimizations\t35249\n"
check "multi-word TYPE 'ADB with optimizations' resolves" \
    "localhost:35249" "$(pontis_endpoint_for "$HW_SERIAL" ADB)"

export MOCK_PONTIS_ROWS="me@host\t${HW_SERIAL}\tADB\t35249\n"
check "single-word TYPE 'ADB' resolves" \
    "localhost:35249" "$(pontis_endpoint_for "$HW_SERIAL" ADB)"

export MOCK_PONTIS_ROWS="me@host\t${HW_SERIAL}\tFastboot\t41017\n"
check "TYPE 'Fastboot' keeps the tcp: scheme" \
    "tcp:127.0.0.1:41017" "$(pontis_endpoint_for "$HW_SERIAL" Fastboot)"

export MOCK_PONTIS_ROWS="me@host\t${HW_SERIAL}\tFastboot with optimizations\t41017\n"
check "multi-word TYPE 'Fastboot with optimizations' resolves" \
    "tcp:127.0.0.1:41017" "$(pontis_endpoint_for "$HW_SERIAL" Fastboot)"

# Columns deliberately reordered.
export MOCK_PONTIS_HEADER='PORT\tTYPE\tID\tBRIDGE\n'
export MOCK_PONTIS_ROWS="35249\tADB with optimizations\t${HW_SERIAL}\tme@host\n"
check "reordered columns still resolve" \
    "localhost:35249" "$(pontis_endpoint_for "$HW_SERIAL" ADB)"
unset MOCK_PONTIS_HEADER

section "pontis_endpoint_for: negative cases"

export MOCK_PONTIS_ROWS="me@host\t${HW_SERIAL}\tADB with optimizations\t35249\n"
pontis_endpoint_for "$HW_SERIAL" Fastboot > /dev/null 2>&1
check "asking for Fastboot when only ADB exists fails" "1" "$?"
check "wrong transport prints nothing" "" \
    "$(pontis_endpoint_for "$HW_SERIAL" Fastboot 2>/dev/null)"

export MOCK_PONTIS_ROWS=''
pontis_endpoint_for "$HW_SERIAL" ADB > /dev/null 2>&1
check "empty listing fails" "1" "$?"

# A different device whose serial merely contains ours, plus a BRIDGE column
# that also contains it. Neither may match.
export MOCK_PONTIS_ROWS="${HW_SERIAL}@host\tSOMEOTHER${HW_SERIAL}X\tADB\t99999\n"
pontis_endpoint_for "$HW_SERIAL" ADB > /dev/null 2>&1
check "substring serial and BRIDGE column do not match" "1" "$?"

export MOCK_PONTIS_ROWS="${HW_SERIAL}@host\tOTHERSERIAL\tFastboot\t41017\n"
check "BRIDGE-column serial is not matched" "" \
    "$(pontis_endpoint_for "$HW_SERIAL" Fastboot 2>/dev/null)"

export MOCK_PONTIS_ROWS="me@host\t${HW_SERIAL}\tADB\t35249\n"
pontis_endpoint_for "" ADB > /dev/null 2>&1
check "missing serial argument fails" "1" "$?"

check "unknown serial resolves to nothing" "" \
    "$(pontis_endpoint_for DEADBEEF ADB 2>/dev/null)"

section "fastboot_getvar"

reset_mocks
export MOCK_FB_tcp_127_0_0_1_41017_serialno="$HW_SERIAL"
export MOCK_FB_tcp_127_0_0_1_41017_product="shiba"
export MOCK_FB_tcp_127_0_0_1_41017_current_slot="a"
export MOCK_FB_tcp_127_0_0_1_41017_has_slot_pvmfw="yes"

check "reads serialno" "$HW_SERIAL" \
    "$(fastboot_getvar tcp:127.0.0.1:41017 serialno 2>/dev/null)"
check "reads lowercase product" "shiba" \
    "$(fastboot_getvar tcp:127.0.0.1:41017 product 2>/dev/null)"
check "reads current-slot" "a" \
    "$(fastboot_getvar tcp:127.0.0.1:41017 current-slot 2>/dev/null)"
check "reads has-slot:pvmfw (colon in the name)" "yes" \
    "$(fastboot_getvar tcp:127.0.0.1:41017 has-slot:pvmfw 2>/dev/null)"

fastboot_getvar tcp:127.0.0.1:41017 nosuchvar > /dev/null 2>&1
check "a missing var is a failure" "1" "$?"

if slow_enabled; then
    export MOCK_FB_HANG=1
    START=$(date +%s)
    fastboot_getvar tcp:127.0.0.1:41017 serialno 3s > /dev/null 2>&1
    RC=$?
    ELAPSED=$(( $(date +%s) - START ))
    unset MOCK_FB_HANG
    check "a hanging transport is a failure, not a hang" "1" "$RC"
    check_range "the hanging transport is bounded" 0 8 "$ELAPSED"
else
    skip_test "a hanging transport is bounded" "SKIP_SLOW"
fi

section "device_util::init: happy paths"

reset_mocks
export MOCK_PONTIS_ROWS="me@host\t${HW_SERIAL}\tADB with optimizations\t35249\n"
export MOCK_ADB_DEVICES='localhost:35249\tdevice\n'
export MOCK_ADB_GOOD_ENDPOINT="localhost:35249"

# Must NOT run inside a command substitution: init sets globals, and a subshell
# would discard them.
device_util::init "$HW_SERIAL" > /dev/null 2>&1; rc=$?
check "init via Pontis ADB succeeds" "0" "$rc"
check "init resolves the adb endpoint" "localhost:35249" "$(device_util::get_adb_serial)"
check "init sets mode ADB" "ADB" "$_DEVICE_UTIL_MODE"
check "init detects PHYSICAL" "PHYSICAL" "$_DEVICE_UTIL_TYPE"

# Plain USB attachment: the hardware serial shows up directly, no Pontis at all.
reset_mocks
export MOCK_ADB_DEVICES="${HW_SERIAL}\tdevice\n"
export MOCK_ADB_GOOD_ENDPOINT="$HW_SERIAL"
device_util::init "$HW_SERIAL" > /dev/null 2>&1
check "plain USB attachment still works" "$HW_SERIAL" "$(device_util::get_adb_serial)"

# Fastboot via Pontis.
reset_mocks
export MOCK_PONTIS_ROWS="me@host\t${HW_SERIAL}\tFastboot\t41017\n"
export MOCK_FB_DEVICES='tcp:127.0.0.1:41017\tfastboot\n'
export MOCK_FB_GOOD_ENDPOINT="tcp:127.0.0.1:41017"
device_util::init "$HW_SERIAL" > /dev/null 2>&1
check "init via Pontis Fastboot resolves the endpoint" \
    "tcp:127.0.0.1:41017" "$(device_util::get_fastboot_serial)"

section "device_util::init: the safety net"

# Pontis is completely broken, but the device is reachable. The probe fallback
# must save us. This is the whole point of the init refactor.
reset_mocks
export MOCK_PONTIS_ROWS='totally\tgarbled\toutput\n'
export MOCK_ADB_DEVICES='localhost:35249\tdevice\n'
export MOCK_ADB_GOOD_ENDPOINT="localhost:35249"
device_util::init "$HW_SERIAL" > /dev/null 2>&1; rc=$?
check "broken Pontis output falls back to probing (rc)" "0" "$rc"
check "broken Pontis output falls back to probing (serial)" \
    "localhost:35249" "$(device_util::get_adb_serial)"

# Pontis binary missing entirely.
mv "$STUB_ROOT/bin/pontis" "$STUB_ROOT/pontis.disabled"
device_util::init "$HW_SERIAL" > /dev/null 2>&1; rc=$?
check "an absent pontis binary falls back to probing" "0" "$rc"
check "an absent pontis binary still resolves the serial" \
    "localhost:35249" "$(device_util::get_adb_serial)"
mv "$STUB_ROOT/pontis.disabled" "$STUB_ROOT/bin/pontis"

section "device_util::init: negative cases"

# 'offline' must not count as found. The old 'adb devices | grep' accepted it.
reset_mocks
export MOCK_ADB_DEVICES="${HW_SERIAL}\toffline\n"
device_util::init "$HW_SERIAL" > /dev/null 2>&1
check "an offline device is not treated as found" "1" "$?"

export MOCK_ADB_DEVICES="${HW_SERIAL}\tunauthorized\n"
device_util::init "$HW_SERIAL" > /dev/null 2>&1
check "an unauthorized device is not treated as found" "1" "$?"

export MOCK_ADB_DEVICES=''
out=$(device_util::init "$HW_SERIAL" 2>&1); rc=$?
check "nothing attached fails" "1" "$rc"
check "the final error message is the summary one" "yes" \
    "$([[ "$out" == *"not found in ADB, Fastboot, or Pontis"* ]] && echo yes || echo "no: $out")"
check "the quiet probe suppresses per-transport errors" "yes" \
    "$([[ "$out" == *"No devices are present in adb mode"* ]] && echo "no: leaked" || echo yes)"

device_util::init "" > /dev/null 2>&1
check "an empty serial fails" "1" "$?"

section "REGRESSION: Pontis device in Fastboot, getvar hangs forever"

reset_mocks
export MOCK_FB_DEVICES='tcp:127.0.0.1:41017\t fastboot\n'
export MOCK_PONTIS_ROWS="me@host.corp.google.com\t${HW_SERIAL}\tFastboot\t41017\n"
export MOCK_FB_HANG=1   # any getvar would block for 600s

START=$(date +%s)
is_device_in_fastboot > /dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
unset MOCK_FB_HANG

check "is_device_in_fastboot succeeds" "0" "$RC"
check "FASTBOOT_SERIAL_NUMBER is the bridged endpoint" \
    "tcp:127.0.0.1:41017" "$FASTBOOT_SERIAL_NUMBER"
check "DEVICE_SERIAL_NUMBER is the hardware serial" "$HW_SERIAL" "$DEVICE_SERIAL_NUMBER"
check "THROUGH_PONTIS is set" "true" "$THROUGH_PONTIS"
check_range "it completes promptly (it used to hang forever)" 0 10 "$ELAPSED"

section "is_device_in_fastboot: other paths"

if slow_enabled; then
    # No pontis record and a hanging transport must still fail, in bounded time.
    reset_mocks
    export MOCK_FB_DEVICES='tcp:127.0.0.1:41017\t fastboot\n'
    export MOCK_FB_HANG=1
    saved_fb_timeout="${DEFAULT_FASTBOOT_TIMEOUT:-15s}"
    DEFAULT_FASTBOOT_TIMEOUT=3s
    START=$(date +%s)
    is_device_in_fastboot > /dev/null 2>&1
    RC=$?
    ELAPSED=$(( $(date +%s) - START ))
    unset MOCK_FB_HANG
    DEFAULT_FASTBOOT_TIMEOUT="$saved_fb_timeout"
    check "no pontis record plus a hanging transport fails" "1" "$RC"
    check_range "and the failure is bounded" 0 10 "$ELAPSED"
else
    skip_test "no pontis record plus a hanging transport fails in bounded time" "SKIP_SLOW"
fi

# Plain USB device, no Pontis involvement.
reset_mocks
export MOCK_FB_DEVICES="${HW_SERIAL}\t fastboot\n"
is_device_in_fastboot > /dev/null 2>&1
check "a direct serial match still works" "0" "$?"
check "FASTBOOT_SERIAL_NUMBER is the raw serial" "$HW_SERIAL" "$FASTBOOT_SERIAL_NUMBER"

# Probe fallback across several endpoints.
reset_mocks
export MOCK_FB_DEVICES='tcp:127.0.0.1:11111\t fastboot\ntcp:127.0.0.1:41017\t fastboot\n'
export MOCK_FB_tcp_127_0_0_1_11111_serialno="OTHERDEVICE"
export MOCK_FB_tcp_127_0_0_1_41017_serialno="$HW_SERIAL"
is_device_in_fastboot > /dev/null 2>&1
check "the probe finds the correct endpoint" "0" "$?"
check "and picks the right one of several" "tcp:127.0.0.1:41017" "$FASTBOOT_SERIAL_NUMBER"

section "is_device_in_adb via Pontis"

# Real 'adb devices' lists a Pontis-bridged device as 'localhost:<port>'.
# adb rejects the 'tcp:127.0.0.1:<port>' spelling with 'device not found';
# only fastboot uses that form.
reset_mocks
export MOCK_ADB_DEVICES='localhost:41017\tdevice\n'
export MOCK_PONTIS_ROWS="me@host.corp.google.com\t${HW_SERIAL}\tADB with optimizations\t41017\n"
export MOCK_ADB_HANG=1   # getprop probing would block
START=$(date +%s)
is_device_in_adb > /dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
unset MOCK_ADB_HANG
check "is_device_in_adb succeeds" "0" "$RC"
check "ADB_SERIAL_NUMBER is the localhost endpoint" "localhost:41017" "$ADB_SERIAL_NUMBER"
check "THROUGH_PONTIS is set" "true" "$THROUGH_PONTIS"
check_range "it short-circuits instead of probing" 0 10 "$ELAPSED"

section "device_util::init via Pontis (Fastboot), transport hanging"

reset_mocks
export MOCK_FB_DEVICES='tcp:127.0.0.1:41017\t fastboot\n'
export MOCK_PONTIS_ROWS="me@host.corp.google.com\t${HW_SERIAL}\tFastboot\t41017\n"
export MOCK_FB_HANG=1
START=$(date +%s)
device_util::init "$HW_SERIAL" > /dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
unset MOCK_FB_HANG
check "device_util::init succeeds" "0" "$RC"
check "the fastboot serial is resolved" \
    "tcp:127.0.0.1:41017" "$(device_util::get_fastboot_serial)"
check_range "it completes promptly" 0 10 "$ELAPSED"

finish_tests
