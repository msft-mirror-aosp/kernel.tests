#!/usr/bin/env bash
# Tests for the atest log directory parsing in build_matrix_runner.sh.
#
# The property that matters: when atest prints no "Test logs:" line, the job
# must degrade on its own and the matrix run must carry on. Before the fix the
# failing grep ended the whole script, which also skipped virtual device
# teardown and leaked a cloud instance.

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
RUNNER="${SANDBOX}/tools/build_matrix_runner/build_matrix_runner.sh"
OURS="ins-cccc3333-16407304-aosp-cf-x86-64-only-phone"
RUN_ID="fixedrun"

# Writes a two job config, so a test can prove the second job still runs after
# the first one goes wrong.
function make_two_job_config() {
    local path="$1" device_type="$2"
    cat > "$path" <<EOF
{
  "global_config": {
    "test_timeout": "5s",
    "test_suite": "dummy_suite"
  },
  "jobs": [
    {
      "job_id": "job_one",
      "display_name": "Job One",
      "device_type": "${device_type}",
      "serial_port": "127.0.0.1:6520",
      "builds": {
        "pb": {
          "branch": "git_main",
          "target": "aosp_cf_x86_64_only_phone-trunk_staging-userdebug",
          "build_id": "16407304"
        }
      }
    },
    {
      "job_id": "job_two",
      "display_name": "Job Two",
      "device_type": "${device_type}",
      "serial_port": "127.0.0.1:6520",
      "builds": {
        "pb": {
          "branch": "git_main",
          "target": "aosp_cf_x86_64_only_phone-trunk_staging-userdebug",
          "build_id": "16407304"
        }
      }
    }
  ]
}
EOF
}

function run_matrix() {
    local config="$1"
    shift
    rm -rf "${SANDBOX}/state/reports"
    : > "${SANDBOX}/state/acloud.log"
    printf 'ins-bystander-000-target\n' > "${SANDBOX}/state/acloud_instances"
    (
        export PATH="${SANDBOX}/bin:${PATH}"
        export STUB_STATE_DIR="${SANDBOX}/state"
        export STUB_NEW_INSTANCE="$OURS"
        "$@" "$RUNNER" -c "$config" \
            -od "${SANDBOX}/state/reports" --run-id "$RUN_ID" \
            > "${SANDBOX}/state/run.log" 2>&1
        echo "$?" > "${SANDBOX}/state/run.rc"
    )
}

function rc()              { cat "${SANDBOX}/state/run.rc"; }
function log_has()         { grep -qF -- "$1" "${SANDBOX}/state/run.log" && echo yes || echo no; }
function reached_summary() { log_has "Matrix Run Summary:"; }
function deletes()         { grep -c '^acloud delete' "${SANDBOX}/state/acloud.log" || true; }
function report_of()       { echo "${SANDBOX}/state/reports/${RUN_ID}/$1"; }

make_sandbox "$SANDBOX"
printf '127.0.0.1:6520\tdevice\n' > "${SANDBOX}/state/adb_devices"
CONFIG="${SANDBOX}/matrix.json"
make_two_job_config "$CONFIG" virtual

section "atest prints no log path"

run_matrix "$CONFIG" env TEST_STUB_MODE=nologline
check "the run is not aborted" "yes" "$(reached_summary)"
check "the run exits cleanly" "0" "$(rc)"
check "both jobs succeed" "yes" "$(log_has 'TOTAL SUCCESS: 2')"
check "the missing log path is reported" "yes" \
    "$(log_has 'Could not extract ATest log directory')"
check "the second job still runs" "yes" "$(log_has 'Job Two')"
check "stdout is still kept for job one" "yes" \
    "$([[ -s "$(report_of job_one)/runner_stdout.log" ]] && echo yes || echo no)"
check "stdout is still kept for job two" "yes" \
    "$([[ -s "$(report_of job_two)/runner_stdout.log" ]] && echo yes || echo no)"
# The teardown is the reason this bug was worth fixing: an abort here would
# have left the cloud instance running.
check "both devices are still torn down" "2" "$(deletes)"
check "teardown never uses --all" "no" \
    "$(grep -q -- '--all' "${SANDBOX}/state/acloud.log" && echo yes || echo no)"

section "atest crashes before printing anything"

run_matrix "$CONFIG" env TEST_STUB_MODE=crash
check "crash: the run is not aborted" "yes" "$(reached_summary)"
check "crash: both jobs are marked as errors" "yes" "$(log_has 'TOTAL ERROR: 2')"
check "crash: the run reports failure" "1" "$(rc)"
check "crash: the second job still runs" "yes" "$(log_has 'Job Two')"
check "crash: both devices are still torn down" "2" "$(deletes)"

section "atest hangs and is timed out"

if slow_enabled; then
    run_matrix "$CONFIG" env TEST_STUB_MODE=hang
    check "timeout: the run is not aborted" "yes" "$(reached_summary)"
    check "timeout: the timeout is named" "yes" "$(log_has 'Tests timed out after')"
    check "timeout: both jobs are marked as errors" "yes" "$(log_has 'TOTAL ERROR: 2')"
    check "timeout: both devices are still torn down" "2" "$(deletes)"
else
    skip_test "atest hangs and is timed out" "SKIP_SLOW"
fi

section "the normal path is unchanged"

run_matrix "$CONFIG" env TEST_STUB_MODE=success
check "success: the run exits cleanly" "0" "$(rc)"
check "success: both jobs succeed" "yes" "$(log_has 'TOTAL SUCCESS: 2')"
check "success: no warning about the log path" "no" \
    "$(log_has 'Could not extract ATest log directory')"
check "success: the atest logs are copied" "yes" \
    "$([[ -f "$(report_of job_one)/result.txt" ]] && echo yes || echo no)"
check "success: the copy is reported" "yes" "$(log_has 'Copying test logs from')"
check "success: both devices are torn down" "2" "$(deletes)"

section "physical jobs are unaffected"

PHYS_CONFIG="${SANDBOX}/matrix_phys.json"
make_two_job_config "$PHYS_CONFIG" physical
run_matrix "$PHYS_CONFIG" env TEST_STUB_MODE=nologline
check "physical: the run is not aborted" "yes" "$(reached_summary)"
check "physical: acloud is never called" "0" "$(deletes)"

section "the old code really did abort (regression proof)"

# Put the pre-fix line back in the sandbox copy only, and show the difference.
# If the implementation is reworked this patch stops applying, and the block
# below skips rather than reporting a phantom failure.
if python3 - "$RUNNER" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
fixed = """                ATEST_LOG_DIR=$(grep 'Test logs:' "$ATEST_LOG_FILE" \\
                    | awk '{print $3}' | sed 's|/log$||' | head -n 1) || true"""
broken = """                ATEST_LOG_DIR=$(grep 'Test logs:' "$ATEST_LOG_FILE" | awk '{print $3}' | sed 's|/log$||' | head -n 1)"""
if fixed not in src:
    sys.exit(1)
open(path, "w").write(src.replace(fixed, broken))
PY
then
    run_matrix "$CONFIG" env TEST_STUB_MODE=nologline
    check "old code: the run is aborted before the summary" "no" "$(reached_summary)"
    check "old code: job two never runs" "no" "$(log_has 'Job Two')"
    check "old code: the device is left running" "0" "$(deletes)"
else
    skip_test "old code: the pre-fix behaviour is reproduced" \
        "the guarded line has changed; update this test"
fi

if (( TESTS_FAIL > 0 )); then
    echo "--- last run log ---"
    tail -n 40 "${SANDBOX}/state/run.log"
fi

finish_tests
