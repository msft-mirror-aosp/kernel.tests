#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

#
# Device Interaction Library
# Wraps ADB and Fastboot operations with context management.
#
# Usage:
#   source path/to/device_util.sh
#   device_util::init "$serial_number"
#   device_util::unlock_screen
#

# --- Include Guard ---
if [[ -n "${__DEVICE_UTIL_SOURCED__:-}" ]]; then
    return 0
fi
readonly __DEVICE_UTIL_SOURCED__=1

# --- Dependencies ---
if [[ -z "${__COMMON_LIB_SOURCED__:-}" ]]; then
    _DEVICE_UTIL_SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
    _DEVICE_UTIL_SCRIPT_DIR="$(dirname "${_DEVICE_UTIL_SCRIPT_PATH}")"
    _COMMON_LIB_PATH="${_DEVICE_UTIL_SCRIPT_DIR}/../common_lib.sh"

    if [[ ! -f "$_COMMON_LIB_PATH" ]]; then
        echo "FATAL ERROR (device_util): Cannot find common_lib.sh" >&2
        return 1
    fi

    if ! source "$_COMMON_LIB_PATH"; then
        echo "FATAL ERROR (device_util): Failed to source library '$_COMMON_LIB_PATH'" >&2
        return 1
    fi
fi

# --- Internal State ---
_DEVICE_UTIL_INPUT_SERIAL=""
_DEVICE_UTIL_ADB_SERIAL=""
_DEVICE_UTIL_FASTBOOT_SERIAL=""
_DEVICE_UTIL_MODE=""     # "ADB" or "FASTBOOT"
_DEVICE_UTIL_TYPE=""     # "PHYSICAL" or "VIRTUAL"

# --- Helper Functions (Internal) ---

# Returns 0 if $1 appears verbatim as a whole line in the newline-separated $2.
function _device_util::list_contains() {
    local needle="$1"
    local haystack="$2"
    grep -qxF -- "$needle" <<< "$haystack"
}

# Arguments:
#   $1 - Hardware serial to look for.
#   $2 - Optional 'true' to suppress the not-found errors. Use this when merely
#        probing a transport the device may legitimately not be on.
function _device_util::find_fastboot_serial() {
    local target_serial="$1"
    local quiet="${2:-false}"
    local device_ids
    device_ids=$(fastboot devices | awk '{print $1}')

    if [[ -z "${device_ids//[[:space:]]/}" ]]; then
        [[ "$quiet" == "true" ]] || log_error "No devices are present in fastboot mode."
        return 1
    fi

    # The endpoint may already be the hardware serial (plain USB attachment).
    if _device_util::list_contains "$target_serial" "$device_ids"; then
        _DEVICE_UTIL_FASTBOOT_SERIAL="$target_serial"
        log_info "Device $target_serial is directly attached in fastboot"
        return 0
    fi

    # Fast path: let Pontis tell us the endpoint instead of probing every one of
    # them with 'getvar serialno', which is slow and can hang over TCP.
    local pontis_ep
    if pontis_ep=$(pontis_endpoint_for "$target_serial" "Fastboot"); then
        if _device_util::list_contains "$pontis_ep" "$device_ids"; then
            _DEVICE_UTIL_FASTBOOT_SERIAL="$pontis_ep"
            log_info "Device $target_serial resolved via Pontis to $pontis_ep"
            return 0
        fi
        log_warn "Pontis reports $target_serial at $pontis_ep, but \
'fastboot devices' does not list it. Falling back to probing."
    fi

    while IFS= read -r device_id; do
        # Skip empty lines
        [[ -z "$device_id" ]] && continue

        local detected_serial
        detected_serial=$(fastboot_getvar "$device_id" "serialno") || continue

        if [[ "$detected_serial" == "$target_serial" ]]; then
            _DEVICE_UTIL_FASTBOOT_SERIAL="$device_id"
            log_info "Device $target_serial matches fastboot id $_DEVICE_UTIL_FASTBOOT_SERIAL"
            return 0
        fi
    done <<< "$device_ids"

    [[ "$quiet" == "true" ]] || \
        log_error "Cannot find device in fastboot with serial: $target_serial"
    return 1
}

# Arguments:
#   $1 - Hardware serial to look for.
#   $2 - Optional 'true' to suppress the not-found error. Use this when merely
#        probing a transport the device may legitimately not be on.
function _device_util::find_adb_serial() {
    local target_serial="$1"
    local quiet="${2:-false}"
    # Gated on 'quiet' because a retry loop would otherwise repeat this on every
    # poll, and the success line below already reports the outcome.
    [[ "$quiet" == "true" ]] || \
        log_info "Searching for device $target_serial in adb devices..."

    local _device_ids
    _device_ids=$(adb devices | awk '$2 == "device" {print $1}')

    if [[ -z "${_device_ids//[[:space:]]/}" ]]; then
        [[ "$quiet" == "true" ]] || log_error "No devices are present in adb mode."
        return 1
    fi

    # The endpoint may already be the hardware serial (plain USB attachment).
    if _device_util::list_contains "$target_serial" "$_device_ids"; then
        _DEVICE_UTIL_ADB_SERIAL="$target_serial"
        log_info "Device $target_serial is directly attached in adb"
        return 0
    fi

    # Fast path: ask Pontis rather than getprop-probing every attached device.
    local pontis_ep
    if pontis_ep=$(pontis_endpoint_for "$target_serial" "ADB"); then
        if _device_util::list_contains "$pontis_ep" "$_device_ids"; then
            _DEVICE_UTIL_ADB_SERIAL="$pontis_ep"
            log_info "Device $target_serial resolved via Pontis to $pontis_ep"
            return 0
        fi
        log_warn "Pontis reports $target_serial at $pontis_ep, but it is not \
listed as an available adb device. Falling back to probing."
    fi

    while IFS= read -r device_id; do
        # Skip empty lines
        [[ -z "$device_id" ]] && continue

        local detected_serial
        detected_serial=$(adb_getprop "$device_id" "ro.serialno")

        if [[ "$detected_serial" == "$target_serial" ]]; then
            _DEVICE_UTIL_ADB_SERIAL="$device_id"
            log_info "Device $target_serial matches adb id $_DEVICE_UTIL_ADB_SERIAL"
            return 0
        fi
    done <<< "$_device_ids"

    [[ "$quiet" == "true" ]] || \
        log_error "Cannot find device in adb with serial: $target_serial. Check USB/Auth."
    return 1
}

# Finds the device on whichever transport it currently sits on and records the
# resulting mode. Split out of device_util::init so it can be retried.
#
# Both find_* helpers already implement the full three-step resolution:
#   1. direct serial match (plain USB attachment)
#   2. Pontis fast path
#   3. per-endpoint probe with getprop / getvar
#
# Do not re-implement detection here. The inline 'adb devices | grep' checks
# that init used to carry had no step 3, so they only ever matched a plain USB
# serial, and every bridged device depended solely on the Pontis fast path. One
# parsing failure there then failed the whole job even though the device was
# perfectly reachable. Going through the helpers keeps the probe as a safety
# net. The grep also matched devices in 'offline' or 'unauthorized' state, while
# the helpers correctly require state 'device'.
function _device_util::resolve_transport() {
    local serial="$1"

    # Probe quietly: the device can only be on one transport, so a miss on the
    # other one is expected and must not look like an error.
    if _device_util::find_adb_serial "$serial" "true"; then
        _DEVICE_UTIL_MODE="ADB"
        return 0
    fi

    if _device_util::find_fastboot_serial "$serial" "true"; then
        _DEVICE_UTIL_MODE="FASTBOOT"
        return 0
    fi

    return 1
}

# --- Public Functions ---

# Resolves a device and records its transport and type for later calls.
#
# Arguments:
#   $1 - Hardware serial, as printed by 'adb shell getprop ro.serialno'.
#   $2 - Optional wait budget, a DURATION string such as '3m'. Defaults to '0',
#        meaning check once and return immediately.
#
# Returns:
#   0 on success, 1 otherwise.
#
# Notes:
#   * The default of '0' preserves the original behaviour for callers that use
#     this as a quick "is the device here?" probe. Only pass a budget where
#     blocking is acceptable, such as right after a reboot, where a bridged
#     device can take tens of seconds to reappear.
function device_util::init() {
    local serial="$1"
    local wait_spec="${2:-0}"

    if [[ -z "$serial" ]]; then
        log_error "Serial number is required."
        return 1
    fi

    _DEVICE_UTIL_INPUT_SERIAL="$serial"
    _DEVICE_UTIL_ADB_SERIAL=""
    _DEVICE_UTIL_FASTBOOT_SERIAL=""
    _DEVICE_UTIL_MODE=""
    _DEVICE_UTIL_TYPE=""

    # wait_for_condition invokes its command in the current shell rather than a
    # subshell, so the globals that _device_util::resolve_transport sets survive.
    if ! wait_for_condition "$wait_spec" "${DEFAULT_DEVICE_POLL_INTERVAL:-5s}" \
            "device $serial to appear in ADB or Fastboot" \
            _device_util::resolve_transport "$serial"; then
        # Collapse every failure, including a timeout, into 1. Callers only
        # test this as a boolean and the original contract returned 1.
        log_error "Device '$serial' not found in ADB, Fastboot, or Pontis."
        return 1
    fi

    # Determine Type (Physical vs Virtual)
    if [[ "$_DEVICE_UTIL_MODE" == "ADB" ]]; then
        local product
        product=$(adb -s "$_DEVICE_UTIL_ADB_SERIAL" shell getprop ro.product.board < /dev/null)
        if [[ "$product" == "cutf" || "$product" == "vsoc_x86"* ]]; then
            _DEVICE_UTIL_TYPE="VIRTUAL"
        else
            _DEVICE_UTIL_TYPE="PHYSICAL"
        fi
    else
        # Default to Physical for Fastboot unless we have better heuristics
        _DEVICE_UTIL_TYPE="PHYSICAL"
    fi

    log_info "Context set. Serial: $_DEVICE_UTIL_INPUT_SERIAL, Mode: $_DEVICE_UTIL_MODE, Type: $_DEVICE_UTIL_TYPE"
    return 0
}

function device_util::run_adb() {
    if [[ -z "$_DEVICE_UTIL_ADB_SERIAL" ]]; then
        log_error "No ADB serial available. Is the device in ADB mode?"
        return 1
    fi
    adb -s "$_DEVICE_UTIL_ADB_SERIAL" "$@"
}

function device_util::run_fastboot() {
    if [[ -z "$_DEVICE_UTIL_FASTBOOT_SERIAL" ]]; then
        log_error "No Fastboot serial available. Is the device in Fastboot mode?"
        return 1
    fi
    fastboot -s "$_DEVICE_UTIL_FASTBOOT_SERIAL" "$@"
}

function device_util::get_adb_serial() {
    echo "$_DEVICE_UTIL_ADB_SERIAL"
}

function device_util::get_fastboot_serial() {
    echo "$_DEVICE_UTIL_FASTBOOT_SERIAL"
}

function device_util::skip_setup_wizard() {
    if [[ "$_DEVICE_UTIL_MODE" != "ADB" ]]; then
        log_warn "Device not in ADB mode. Skipping."
        return 1
    fi

    local serial="$_DEVICE_UTIL_ADB_SERIAL"
    log_info "Checking package manager status..."

    # Wait for PM to be ready
    local retries=30
    while ! device_util::run_adb shell pm path com.android.settings > /dev/null 2>&1; do
        sleep 2
        ((retries--))
        if ((retries <= 0)); then
             log_warn "Timeout waiting for package manager."
             return 1
        fi
    done

    log_info "Disabling Setup Wizard..."
    device_util::run_adb shell settings put global setup_wizard_has_run 1
    device_util::run_adb shell settings put global device_provisioned 1
    device_util::run_adb shell settings put secure user_setup_complete 1

    # Attempt to disable the wizard apps directly (Supports newer devices)
    local wizard_pkgs
    wizard_pkgs=$(device_util::run_adb shell pm list packages | grep -Ei 'setupwizard|setupwraith' | cut -d':' -f2 | tr -d '\r')

    for pkg in $wizard_pkgs; do
        if [[ -n "$pkg" ]]; then
            log_info "Disabling package $pkg"
            device_util::run_adb shell pm disable-user --user 0 "$pkg"
        fi
    done

    log_info "Sending HOME intent to bypass the screen..."
    device_util::run_adb shell am start -a android.intent.action.MAIN -c android.intent.category.HOME > /dev/null 2>&1
}

function device_util::unlock_screen() {
    if [[ "$_DEVICE_UTIL_MODE" != "ADB" ]]; then
        log_warn "Device not in ADB mode. Skipping."
        return 1
    fi

    log_info "Waiting for boot complete..."
    device_util::wait_for_boot_complete || return 1

    log_info "Checking screen state..."
    local dumpsys_out
    dumpsys_out=$(device_util::run_adb shell dumpsys deviceidle)

    local is_screen_on
    is_screen_on=$(echo "$dumpsys_out" | grep "mScreenOn" | cut -d'=' -f2)

    if [[ "$is_screen_on" == "false" ]]; then
        log_info "Turning screen ON..."
        device_util::run_adb shell input keyevent 26 # POWER
        sleep 1
        dumpsys_out=$(device_util::run_adb shell dumpsys deviceidle)
        is_screen_on=$(echo "$dumpsys_out" | grep "mScreenOn" | cut -d'=' -f2)
    fi

    if [[ "$is_screen_on" == "true" ]]; then
        local is_locked
        is_locked=$(echo "$dumpsys_out" | grep "mScreenLocked" | cut -d'=' -f2)

        if [[ "$is_locked" == "true" ]]; then
            log_info "Sending MENU key to unlock..."
            device_util::run_adb shell input keyevent 82 # MENU
        else
            log_info "Screen is already unlocked."
        fi
    else
         log_error "Failed to turn on screen."
         return 1
    fi
}

function device_util::wait_for_boot_complete() {
    local timeout_sec="${1:-120}"
    local start_time
    start_time=$(date +%s)

    if [[ -z "$_DEVICE_UTIL_ADB_SERIAL" ]]; then
        log_error "No ADB serial available. Is the device in ADB mode?"
        return 1
    fi

    # 'adb wait-for-device' blocks forever by default, which would make the poll
    # loop below unreachable. Cap it at the same overall budget.
    if ! run_with_timeout "${timeout_sec}s" \
            adb -s "$_DEVICE_UTIL_ADB_SERIAL" wait-for-device; then
        log_error "Device $_DEVICE_UTIL_ADB_SERIAL did not appear in adb within ${timeout_sec}s."
        return 1
    fi

    log_info "Waiting for sys.boot_completed..."
    while true; do
        local boot_complete
        boot_complete=$(adb_getprop "$_DEVICE_UTIL_ADB_SERIAL" "sys.boot_completed")

        if [[ "$boot_complete" == "1" ]]; then
            return 0
        fi

        local current_time
        current_time=$(date +%s)
        if (( current_time - start_time > timeout_sec )); then
            log_error "Timeout waiting for boot complete."
            return 1
        fi
        sleep 3
    done
}

function device_util::ensure_root() {
    if [[ "$_DEVICE_UTIL_MODE" != "ADB" ]]; then return 1; fi

    local id_out
    id_out=$(device_util::run_adb shell id)
    if [[ "$id_out" != *"uid=0(root)"* ]]; then
        log_info "Restarting ADB as root..."
        device_util::run_adb root
        # 'adb root' drops the connection; bound the reconnect so a device that
        # never comes back cannot block here indefinitely.
        if ! run_with_timeout "60s" \
                adb -s "$_DEVICE_UTIL_ADB_SERIAL" wait-for-device; then
            log_error "Device $_DEVICE_UTIL_ADB_SERIAL did not come back after 'adb root'."
            return 1
        fi
    else
        log_info "Already root."
    fi
}

# Safely retrieves an Android device system property via 'adb shell getprop'.
# Arguments:
#   $1 - ADB Device Serial Number (String, Required)
#   $2 - Target System Property Name (String, Required)
#   $3 - Optional Timeout Duration String (Default: '5s')
# Returns:
#   Writes the Whitespace-sanitized property string directly to stdout.
#   Always resolves with exit-code 0 to protect callers from 'set -e' pre-emptive aborts.
function adb_getprop() {
    local device_serial="$1"
    local property_name="$2"
    local timeout_spec="${3:-${DEFAULT_ADB_TIMEOUT:-5s}}"

    local exit_code=0
    local raw_output
    raw_output=$(timeout -k 1s "$timeout_spec" adb -s "$device_serial" shell getprop "$property_name" < /dev/null) || exit_code=$?

    if (( exit_code == 124 || exit_code == 137 )); then
        log_warn "Timeout ($timeout_spec) reached while retrieving $property_name for device '$device_serial'."
    fi

    # Emit the sanitized, whitespace-stripped property string onto stdout
    printf "%s" "${raw_output//[[:space:]]/}"
}

# Safely retrieves a bootloader variable via 'fastboot getvar'.
#
# This is the fastboot-side twin of adb_getprop(). It exists because a bare
# 'fastboot getvar' can block forever on a TCP transport (e.g. a stale Pontis
# tunnel), where it completes the TCP connect but never the fastboot handshake.
#
# Arguments:
#   $1 - Fastboot serial. May be a plain hardware serial or a Pontis endpoint
#        such as 'tcp:127.0.0.1:41017'.
#   $2 - Variable name, e.g. 'serialno', 'product', 'current-slot',
#        'has-slot:pvmfw'. Names containing ':' are handled correctly.
#   $3 - Optional timeout duration (default: $DEFAULT_FASTBOOT_TIMEOUT).
#
# Returns:
#   $EXIT_SUCCESS and writes the parsed, whitespace-stripped value to stdout.
#   $EXIT_FAILURE (with nothing on stdout) if the command timed out, failed, or
#   the variable was absent from the output.
function fastboot_getvar() {
    local device_serial="$1"
    local var_name="$2"
    local timeout_spec="${3:-${DEFAULT_FASTBOOT_TIMEOUT:-15s}}"

    if [[ -z "$device_serial" || -z "$var_name" ]]; then
        log_error "Usage: fastboot_getvar <serial> <var_name> [timeout]"
        return $EXIT_FAILURE
    fi

    # fastboot writes getvar results to stderr on most versions, hence 2>&1.
    # run_with_timeout stays silent on success, so nothing pollutes the capture.
    local raw_output
    local exit_code=0
    raw_output=$(run_with_timeout "$timeout_spec" \
        fastboot -s "$device_serial" getvar "$var_name" 2>&1) || exit_code=$?

    if (( exit_code != 0 )); then
        log_warn "Cannot read fastboot var '$var_name' from '$device_serial' \
(exit $exit_code). The transport may be stale, e.g. a dead Pontis TCP tunnel."
        return $EXIT_FAILURE
    fi

    # Output looks like '<var_name>: <value>'. Match the literal '<var_name>: '
    # prefix rather than splitting on ':', so names like 'has-slot:pvmfw' work.
    local value
    if ! value=$(awk -v k="$var_name" '
            index($0, k ": ") == 1 { print substr($0, length(k) + 3); found = 1; exit }
            END { if (!found) exit 1 }
        ' <<< "$raw_output"); then
        log_warn "Could not find '$var_name' in fastboot output: $raw_output"
        return $EXIT_FAILURE
    fi

    printf "%s" "${value//[[:space:]]/}"
    return $EXIT_SUCCESS
}

# Resolves a hardware serial to the local endpoint that Pontis exposes for it.
#
# Pontis bridges a remote device onto localhost, so 'adb devices' and
# 'fastboot devices' show a local endpoint instead of the hardware serial.
# Asking Pontis directly is deterministic and cheap; probing every endpoint with
# 'getvar serialno' is neither.
#
# Arguments:
#   $1 - Hardware serial, as printed by 'getprop ro.serialno' or
#        'fastboot getvar serialno'.
#   $2 - Desired transport: 'ADB' or 'Fastboot' (matched case-insensitively).
#
# Returns:
#   $EXIT_SUCCESS and writes the endpoint to stdout, or $EXIT_FAILURE if pontis
#   is unavailable or has no such device. The endpoint format differs per
#   transport, see $transport_prefix below.
function pontis_endpoint_for() {
    local serial="$1"
    local want_type="$2"

    if [[ -z "$serial" || -z "$want_type" ]]; then
        log_error "Usage: pontis_endpoint_for <serial> <ADB|Fastboot>"
        return $EXIT_FAILURE
    fi

    command -v pontis &> /dev/null || return $EXIT_FAILURE

    local listing
    listing=$(run_with_timeout "15s" pontis devices 2>/dev/null) || return $EXIT_FAILURE

    # Locate columns via the header row ('BRIDGE ID TYPE PORT') instead of
    # hard-coding indices, so a future column reorder does not silently break us.
    #
    # The listing is TAB separated and a TYPE value may itself contain spaces
    # (Pontis reports 'ADB with optimizations' once the bridge is warmed up).
    # Splitting on any whitespace therefore shifts every column after TYPE and
    # makes PORT read as 'with', so FS must be an explicit tab. TYPE is matched
    # on its first word for the same reason.
    local port
    port=$(awk -F'\t' -v s="$serial" -v t="$want_type" '
        function trim(x) { gsub(/^[ \t]+|[ \t\r]+$/, "", x); return x }
        NR == 1 { for (i = 1; i <= NF; i++) { col[trim($i)] = i }; next }
        col["ID"] && col["TYPE"] && col["PORT"] \
            && trim($col["ID"]) == s \
            && toupper(trim($col["TYPE"])) ~ "^" toupper(t) "( |$)" \
            { print trim($col["PORT"]); exit }
    ' <<< "$listing")

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return $EXIT_FAILURE
    fi

    # adb and fastboot disagree on how a TCP endpoint is spelled: adb wants a
    # bare 'host:port' and rejects 'tcp:127.0.0.1:<port>' with 'device not
    # found', while fastboot requires the 'tcp:' scheme. Emit whichever form the
    # requested transport actually accepts.
    local transport_prefix="tcp:127.0.0.1:"
    if [[ "${want_type^^}" == ADB* ]]; then
        transport_prefix="localhost:"
    fi

    printf "%s%s" "$transport_prefix" "$port"
    return $EXIT_SUCCESS
}
