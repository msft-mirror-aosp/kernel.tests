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
function _device_util::find_fastboot_serial() {
    local target_serial="$1"
    local device_ids
    device_ids=$(fastboot devices | awk '{print $1}')

    while IFS= read -r device_id; do
        # Skip empty lines
        [[ -z "$device_id" ]] && continue

        local _output
        _output=$(fastboot -s "$device_id" getvar serialno 2>&1)
        local detected_serial
        detected_serial=$(echo "$_output" | grep -Po "serialno: \K[A-Z0-9]+")

        if [[ "$detected_serial" == "$target_serial" ]]; then
            _DEVICE_UTIL_FASTBOOT_SERIAL="$device_id"
            log_info "Device $target_serial matches fastboot id $_DEVICE_UTIL_FASTBOOT_SERIAL"
            return 0
        fi
    done <<< "$device_ids"

    log_error "Cannot find device in fastboot with serial: $target_serial"
    return 1
}

function _device_util::find_adb_serial() {
    local target_serial="$1"
    log_info "Searching for device $target_serial in adb devices..."

    local _device_ids
    _device_ids=$(adb devices | awk '$2 == "device" {print $1}')

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

    log_error "Cannot find device in adb with serial: $target_serial. Check USB/Auth."
    return 1
}

# --- Public Functions ---
function device_util::init() {
    local serial="$1"
    if [[ -z "$serial" ]]; then
        log_error "Serial number is required."
        return 1
    fi

    _DEVICE_UTIL_INPUT_SERIAL="$serial"
    _DEVICE_UTIL_ADB_SERIAL=""
    _DEVICE_UTIL_FASTBOOT_SERIAL=""
    _DEVICE_UTIL_MODE=""
    _DEVICE_UTIL_TYPE=""

    local found_device=false

    # Check ADB
    if adb devices | grep -q "$serial"; then
        _DEVICE_UTIL_MODE="ADB"
        _DEVICE_UTIL_ADB_SERIAL="$serial"
        found_device=true
    fi

    # Check Fastboot
    if ! $found_device && fastboot devices | grep -q "$serial"; then
        _DEVICE_UTIL_MODE="FASTBOOT"
        _DEVICE_UTIL_FASTBOOT_SERIAL="$serial"
        found_device=true
    fi

    # Check Pontis (Google internal tool)
    if ! $found_device && command -v pontis &> /dev/null; then
        local pontis_info
        pontis_info=$(pontis devices 2>/dev/null | grep "$serial")
        if [[ "$pontis_info" == *Fastboot* ]]; then
            _DEVICE_UTIL_MODE="FASTBOOT"
            log_info "Device $serial found via Pontis (Fastboot)"
            if ! _device_util::find_fastboot_serial "$serial"; then
                 return 1
            fi
            found_device=true
        elif [[ "$pontis_info" == *ADB* ]]; then
            _DEVICE_UTIL_MODE="ADB"
            log_info "Device $serial found via Pontis (ADB)"
            if ! _device_util::find_adb_serial "$serial"; then
                return 1
            fi
            found_device=true
        fi
    fi

    if ! $found_device; then
        log_error "Device '$serial' not found in ADB, Fastboot, or Pontis."
        return 1
    fi

    # Determine Type (Physical vs Virtual)
    if [[ "$_DEVICE_UTIL_MODE" == "ADB" ]]; then
        local product
        product=$(adb -s "$_DEVICE_UTIL_ADB_SERIAL" shell getprop ro.product.board)
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
    local timeout_sec=120
    local start_time=$(date +%s)

    device_util::run_adb wait-for-device

    log_info "Waiting for sys.boot_completed..."
    while true; do
        local boot_complete
        boot_complete=$(device_util::run_adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')

        if [[ "$boot_complete" == "1" ]]; then
            return 0
        fi

        local current_time=$(date +%s)
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
        device_util::run_adb wait-for-device
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
    local timeout_spec="${3:-5s}"

    local exit_code=0
    local raw_output
    raw_output=$(timeout -k 1s "$timeout_spec" adb -s "$device_serial" shell getprop "$property_name") || exit_code=$?

    if (( exit_code == 124 || exit_code == 137 )); then
        log_warn "Timeout ($timeout_spec) reached while retrieving $property_name for device '$device_serial'."
    fi

    # Emit the sanitized, whitespace-stripped property string onto stdout
    printf "%s" "${raw_output//[[:space:]]/}"
}
