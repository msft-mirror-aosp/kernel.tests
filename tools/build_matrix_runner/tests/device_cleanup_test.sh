#!/usr/bin/env bash
# Tests for precise Cuttlefish teardown in build_matrix_runner.sh.
#
# The property that matters most: instances this run did not create must never
# be deleted, and 'acloud delete --all' must never be issued. Getting this
# wrong once cost somebody their device.
#
# launch_cvd.sh's own --report-file behaviour is covered in
# ../../tests/launch_cvd_test.sh; here the report is only a means to an end.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="$(dirname "${TESTS_DIR}")"
TOOLS_DIR="$(dirname "${RUNNER_DIR}")"
export TOOLS_DIR

# shellcheck source=../../tests/lib/test_common.sh
source "${TOOLS_DIR}/tests/lib/test_common.sh"
# shellcheck source=../../tests/fixtures/matrix_sandbox.sh
source "${TOOLS_DIR}/tests/fixtures/matrix_sandbox.sh"

require_cmd jq python3

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="${TMPROOT}/sandbox"

# Two devices the user already had running. Nothing below may touch them.
BYSTANDER_A="ins-aaaa1111-16391145-aosp-cf-x86-64-only-phone"
BYSTANDER_B="ins-bbbb2222-16407304-aosp-cf-x86-64-only-phone"
OURS="ins-cccc3333-16407304-aosp-cf-x86-64-only-phone"
CONCURRENT="ins-eeee5555-16407304-aosp-cf-x86-64-only-phone"

# Resets the fake cloud to "the user already has two devices running".
function reset_cloud() {
    printf '%s\n%s\n' "$BYSTANDER_A" "$BYSTANDER_B" > "${SANDBOX}/state/acloud_instances"
    : > "${SANDBOX}/state/acloud.log"
    : > "${SANDBOX}/state/launch_argv.log"
}

# Runs the matrix runner. Arguments after the config are environment overrides;
# extra runner flags go in RUNNER_ARGS, because mixing the two would make 'env'
# treat a flag as the command to execute.
RUNNER_ARGS=()
function run_matrix() {
    local config="$1"
    shift
    (
        export PATH="${SANDBOX}/bin:${PATH}"
        export STUB_STATE_DIR="${SANDBOX}/state"
        "$@" "${SANDBOX}/tools/build_matrix_runner/build_matrix_runner.sh" \
            -c "$config" "${RUNNER_ARGS[@]}" > "${SANDBOX}/state/run.log" 2>&1
        echo "$?" > "${SANDBOX}/state/run.rc"
    )
}

function rc()          { cat "${SANDBOX}/state/run.rc"; }
function delete_cmds() { grep '^acloud delete' "${SANDBOX}/state/acloud.log" || true; }
function log_has()     { grep -qF -- "$1" "${SANDBOX}/state/run.log" && echo yes || echo no; }

make_sandbox "$SANDBOX"
printf '127.0.0.1:6520\tdevice\n' > "${SANDBOX}/state/adb_devices"
CONFIG="${SANDBOX}/matrix.json"

section "teardown picks the right instance"

# A successful launch is deleted by adb port.
make_config "$CONFIG" virtual
reset_cloud
LAUNCH_STUB_MODE=success STUB_NEW_INSTANCE="$OURS" run_matrix "$CONFIG" env
check "success: deleted by adb port" "acloud delete --adb-port 6520" "$(delete_cmds)"
check "success: never uses --all" "no" \
    "$(delete_cmds | grep -q -- '--all' && echo yes || echo no)"

# acloud failed cleanly, so the report names the instance.
reset_cloud
LAUNCH_STUB_MODE=bootfail STUB_NEW_INSTANCE="$OURS" STUB_INSTANCE="$OURS" \
    run_matrix "$CONFIG" env
check "boot failure: deleted by name from the report" \
    "acloud delete --instance-names $OURS" "$(delete_cmds)"
check "boot failure: bystanders untouched" "no" \
    "$(delete_cmds | grep -qE "$BYSTANDER_A|$BYSTANDER_B" && echo yes || echo no)"

if slow_enabled; then
    section "teardown after a killed launch"

    # The launch was killed, so there is no report at all. Only the snapshot
    # difference is left to go on.
    make_config "$CONFIG" virtual '"launch_timeout": "5s"'
    reset_cloud
    LAUNCH_STUB_MODE=hang STUB_NEW_INSTANCE="$OURS" run_matrix "$CONFIG" env
    check "killed launch: deleted by the name found in the snapshot" \
        "acloud delete --instance-names $OURS" "$(delete_cmds)"
    check "killed launch: explains where the name came from" "yes" \
        "$(log_has 'appeared during this launch')"
    check "killed launch: bystanders untouched" "no" \
        "$(delete_cmds | grep -qE "$BYSTANDER_A|$BYSTANDER_B" && echo yes || echo no)"

    # Killed launch, but the only new instance belongs to a different build.
    # That is somebody else's device, so nothing may be deleted.
    reset_cloud
    LAUNCH_STUB_MODE=hang STUB_NEW_INSTANCE="ins-dddd4444-99999999-other-target" \
        run_matrix "$CONFIG" env
    check "an unrelated new instance: nothing is deleted" "" "$(delete_cmds)"
    check "an unrelated new instance: the user is told to look" "yes" \
        "$(log_has 'Could not work out which virtual device')"

    # Killed launch with build_id 'latest': the real id never reaches the
    # script, so guessing is not allowed.
    python3 - "$CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["jobs"][0]["builds"]["pb"]["build_id"] = "latest"
json.dump(cfg, open(path, "w"), indent=2)
PY
    reset_cloud
    LAUNCH_STUB_MODE=hang STUB_NEW_INSTANCE="$OURS" run_matrix "$CONFIG" env
    check "build id 'latest': nothing is deleted" "" "$(delete_cmds)"

    # Killed launch that created nothing at all.
    make_config "$CONFIG" virtual '"launch_timeout": "5s"'
    reset_cloud
    LAUNCH_STUB_MODE=hang run_matrix "$CONFIG" env
    check "no new instance: nothing is deleted" "" "$(delete_cmds)"
    check "no new instance: the run still finishes" "1" "$(rc)"

    section "two devices appear at once"

    # Somebody else started a device with the same build id while we were
    # launching. Both look equally new and equally ours, so neither may be
    # touched. This really happened and cost somebody their device.
    reset_cloud
    LAUNCH_STUB_MODE=hang STUB_NEW_INSTANCE="$OURS" \
        STUB_CONCURRENT_INSTANCE="$CONCURRENT" run_matrix "$CONFIG" env
    check "two new instances: nothing is deleted at all" "" "$(delete_cmds)"
    check "two new instances: ours is not deleted either" "no" \
        "$(delete_cmds | grep -qF -- "$OURS" && echo yes || echo no)"
    check "two new instances: the other one is not deleted" "no" \
        "$(delete_cmds | grep -qF -- "$CONCURRENT" && echo yes || echo no)"
    check "two new instances: the ambiguity is reported" "yes" \
        "$(log_has 'Cannot tell which one belongs to this job')"
    check "two new instances: both are named for the user" "yes" \
        "$(log_has "$CONCURRENT")"
    check "two new instances: the run still finishes" "1" "$(rc)"

    # The same ambiguity must not turn into a delete hint under --keep-device.
    reset_cloud
    RUNNER_ARGS=(--keep-device)
    LAUNCH_STUB_MODE=hang STUB_NEW_INSTANCE="$OURS" \
        STUB_CONCURRENT_INSTANCE="$CONCURRENT" run_matrix "$CONFIG" env
    RUNNER_ARGS=()
    check "keep-device with two new: no delete command is suggested" "no" \
        "$(log_has "acloud delete --instance-names $CONCURRENT")"
else
    skip_test "teardown after a killed launch" "SKIP_SLOW"
    skip_test "two devices appear at once" "SKIP_SLOW"
fi

# A report file is authoritative, so it still wins even when a stranger's
# device appeared at the same moment.
make_config "$CONFIG" virtual
reset_cloud
LAUNCH_STUB_MODE=bootfail STUB_NEW_INSTANCE="$OURS" STUB_INSTANCE="$OURS" \
    STUB_CONCURRENT_INSTANCE="$CONCURRENT" run_matrix "$CONFIG" env
check "the report wins over an ambiguous snapshot" \
    "acloud delete --instance-names $OURS" "$(delete_cmds)"
check "the report path leaves the stranger alone" "no" \
    "$(delete_cmds | grep -qF -- "$CONCURRENT" && echo yes || echo no)"

section "teardown is robust"

# acloud throws when an instance has already gone away. That must not stop us.
make_config "$CONFIG" virtual
reset_cloud
LAUNCH_STUB_MODE=success STUB_NEW_INSTANCE="$OURS" \
    run_matrix "$CONFIG" env ACLOUD_DELETE_STUB_MODE=explode
check "acloud delete throwing does not abort the run" "0" "$(rc)"
check "acloud delete throwing is reported" "yes" "$(log_has 'did not finish cleanly')"

if slow_enabled; then
    # A wedged acloud delete must be bounded.
    reset_cloud
    start=$(date +%s)
    LAUNCH_STUB_MODE=success STUB_NEW_INSTANCE="$OURS" \
        run_matrix "$CONFIG" env ACLOUD_DELETE_STUB_MODE=hang \
        DEFAULT_ACLOUD_DELETE_TIMEOUT=5s
    elapsed=$(( $(date +%s) - start ))
    check_range "a wedged acloud delete is cut off" 0 40 "$elapsed"
    check "a wedged acloud delete does not abort the run" "0" "$(rc)"
else
    skip_test "a wedged acloud delete is cut off" "SKIP_SLOW"
fi

section "--keep-device"

make_config "$CONFIG" virtual
reset_cloud
RUNNER_ARGS=(--keep-device)
LAUNCH_STUB_MODE=success STUB_NEW_INSTANCE="$OURS" STUB_INSTANCE="$OURS" \
    run_matrix "$CONFIG" env
RUNNER_ARGS=()
check "keep-device: nothing is deleted" "" "$(delete_cmds)"
check "keep-device: the instance is named in the summary" "yes" \
    "$(log_has "acloud delete --instance-names $OURS")"
check "keep-device: does not suggest --all" "no" "$(log_has 'acloud delete --all')"

if slow_enabled; then
    # Even when the instance cannot be identified, --all must not be suggested.
    make_config "$CONFIG" virtual '"launch_timeout": "5s"'
    reset_cloud
    RUNNER_ARGS=(--keep-device)
    LAUNCH_STUB_MODE=hang run_matrix "$CONFIG" env
    RUNNER_ARGS=()
    check "keep-device with nothing found: still no --all" "no" \
        "$(log_has 'acloud delete --all')"
    check "keep-device with nothing found: gives usable advice" "yes" \
        "$(log_has "Run 'acloud list' to find them")"
else
    skip_test "keep-device with nothing found still avoids --all" "SKIP_SLOW"
fi

section "--reuse-device"

# A job that reused an existing device never took a snapshot. Nothing may be
# reported as "left behind by this run", even when a bystander happens to share
# the build id.
make_config "$CONFIG" virtual
reset_cloud
RUNNER_ARGS=(--reuse-device)
# Pre-seed the state file so the reuse branch is taken and no launch happens.
mkdir -p "${SANDBOX}/tools/build_matrix_runner/out"
echo "job_one=127.0.0.1:6520" > "${SANDBOX}/tools/build_matrix_runner/out/.matrix_active_devices"
LAUNCH_STUB_MODE=success run_matrix "$CONFIG" env
RUNNER_ARGS=()
check "reuse-device: the launch is skipped" "no" "$(log_has 'Launching virtual device')"
check "reuse-device: nothing is deleted" "" "$(delete_cmds)"
check "reuse-device: a bystander is not reported as ours" "no" "$(log_has "$BYSTANDER_B")"
rm -f "${SANDBOX}/tools/build_matrix_runner/out/.matrix_active_devices"

section "untouched paths"

# A physical job must not talk to acloud at all.
make_config "$CONFIG" physical
reset_cloud
FLASH_STUB_MODE=success run_matrix "$CONFIG" env
check "physical: acloud is never called" "" "$(cat "${SANDBOX}/state/acloud.log")"
check "physical: the run succeeds" "0" "$(rc)"

finish_tests
