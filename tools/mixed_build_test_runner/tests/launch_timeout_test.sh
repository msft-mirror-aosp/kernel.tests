#!/usr/bin/env bash
# Tests for the launch and flash timeouts in mixed_build_test_runner.sh.
#
# The runner is driven end to end inside a sandbox where launch_cvd.sh,
# flash_device.sh, run_test_only.sh, adb, acloud and pontis are all stubs, so
# nothing reaches a real device or the cloud.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="$(dirname "${TESTS_DIR}")"
TOOLS_DIR="$(dirname "${RUNNER_DIR}")"
export TOOLS_DIR

# shellcheck source=../../tests/lib/test_common.sh
source "${TOOLS_DIR}/tests/lib/test_common.sh"
# shellcheck source=../../tests/fixtures/matrix_sandbox.sh
source "${TOOLS_DIR}/tests/fixtures/matrix_sandbox.sh"

require_cmd jq

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="${TMPROOT}/sandbox"

# Runs the runner in the sandbox. Echoes elapsed whole seconds; the log
# lands in $SANDBOX/state/run.log and the exit code in $SANDBOX/state/run.rc.
function run_matrix() {
    local config="$1"
    shift
    local start end
    start=$(date +%s)
    (
        export PATH="${SANDBOX}/bin:${PATH}"
        export STUB_STATE_DIR="${SANDBOX}/state"
        "$@" "${SANDBOX}/tools/mixed_build_test_runner/mixed_build_test_runner.sh" \
            -c "$config" > "${SANDBOX}/state/run.log" 2>&1
        echo "$?" > "${SANDBOX}/state/run.rc"
    )
    end=$(date +%s)
    echo $(( end - start ))
}

function rc()      { cat "${SANDBOX}/state/run.rc"; }
function log_has() { grep -qF -- "$1" "${SANDBOX}/state/run.log" && echo yes || echo no; }

make_sandbox "$SANDBOX"
printf '127.0.0.1:6520\tdevice\n' > "${SANDBOX}/state/adb_devices"
CONFIG="${SANDBOX}/matrix.json"

section "the happy path is untouched"

make_config "$CONFIG" virtual
: > "${SANDBOX}/state/acloud.log"
LAUNCH_STUB_MODE=success run_matrix "$CONFIG" env > /dev/null
check "success: the runner exits 0" "0" "$(rc)"
check "success: no timeout is reported" "no" "$(log_has 'timed out after')"
check "success: the launch timeout is announced" "yes" \
    "$(log_has 'Launching virtual device (timeout 30m)')"
check "success: the timeouts line lists launch" "yes" "$(log_has 'launch=30m')"

section "a hung launch is killed at the deadline"

if slow_enabled; then
    make_config "$CONFIG" virtual '"launch_timeout": "5s"'
    rm -f "${SANDBOX}/state/launch_grandchild.pid"
    elapsed=$(LAUNCH_STUB_MODE=hang run_matrix "$CONFIG" env)
    check "hang: reported as a timeout, not a generic failure" "yes" \
        "$(log_has 'Launching virtual device timed out after 5s')"
    check "hang: not misreported as a serial problem" "no" \
        "$(log_has 'Failed to obtain Cuttlefish serial')"
    check "hang: the job is marked failed" "1" "$(rc)"
    check_range "hang: it stopped near the deadline, not later" 5 25 "$elapsed"

    # The grandchild must be gone: 'timeout' signals the whole process group.
    gc_pid=$(cat "${SANDBOX}/state/launch_grandchild.pid" 2>/dev/null)
    if [[ -n "$gc_pid" ]]; then
        sleep 1
        check "hang: the grandchild process was killed too" "no" \
            "$(kill -0 "$gc_pid" 2>/dev/null && echo yes || echo no)"
    else
        check "hang: the grandchild pid was recorded" "yes" "no"
    fi
else
    skip_test "a hung launch is killed at the deadline" "SKIP_SLOW"
fi

section "an ordinary failure keeps its own message"

make_config "$CONFIG" virtual '"launch_timeout": "5s"'
LAUNCH_STUB_MODE=plainfail run_matrix "$CONFIG" env > /dev/null
check "plain failure: not reported as a timeout" "no" "$(log_has 'timed out after')"
check "plain failure: keeps the original message" "yes" \
    "$(log_has 'Failed to obtain Cuttlefish serial')"

# A launch that exits 0 but writes no serial is still a failure, not a timeout.
LAUNCH_STUB_MODE=emptyserial run_matrix "$CONFIG" env > /dev/null
check "empty serial: not reported as a timeout" "no" "$(log_has 'timed out after')"
check "empty serial: still fails the job" "yes" \
    "$(log_has 'Failed to obtain Cuttlefish serial')"

section "where the timeout value comes from"

make_config "$CONFIG" virtual '"launch_timeout": "90s"'
LAUNCH_STUB_MODE=success run_matrix "$CONFIG" env > /dev/null
check "the config launch_timeout is used" "yes" "$(log_has 'launch=90s')"

make_config "$CONFIG" virtual
LAUNCH_STUB_MODE=success run_matrix "$CONFIG" env DEFAULT_LAUNCH_TIMEOUT=7m > /dev/null
check "the DEFAULT_LAUNCH_TIMEOUT env override is used" "yes" "$(log_has 'launch=7m')"

make_config "$CONFIG" virtual '"launch_timeout": "90s"'
LAUNCH_STUB_MODE=success run_matrix "$CONFIG" env DEFAULT_LAUNCH_TIMEOUT=7m > /dev/null
check "the config wins over the env override" "yes" "$(log_has 'launch=90s')"

section "the physical path is unaffected"

make_config "$CONFIG" physical
FLASH_STUB_MODE=success run_matrix "$CONFIG" env > /dev/null
check "physical: still exits 0" "0" "$(rc)"
check "physical: does not run the launch step" "no" "$(log_has 'Launching virtual device')"
check "physical: the flash timeout is unchanged" "yes" "$(log_has 'flash=30m')"

if slow_enabled; then
    make_config "$CONFIG" physical '"flash_timeout": "5s"'
    FLASH_STUB_MODE=hang run_matrix "$CONFIG" env > /dev/null
    check "physical: the flash timeout still fires" "yes" \
        "$(log_has 'Flashing physical device timed out after 5s')"
else
    skip_test "physical: the flash timeout still fires" "SKIP_SLOW"
fi

finish_tests
