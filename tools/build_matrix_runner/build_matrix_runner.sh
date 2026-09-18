#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# A script to run ATest against a matrix of device builds (Cuttlefish or physical device).
# It parses the provided e2e_matrix.json, provisions the devices, runs ATest, and
# collects the generated logs into a structured report folder.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TOOLS_DIR="$( dirname "$SCRIPT_DIR" )"

# --- Scripts ---
readonly LAUNCH_CVD_SCRIPT="${TOOLS_DIR}/launch_cvd.sh"
readonly FLASH_DEVICE_SCRIPT="${TOOLS_DIR}/flash_device.sh"
readonly RUN_TEST_SCRIPT="${TOOLS_DIR}/run_test_only.sh"

LIB_PATH="${TOOLS_DIR}/common_lib.sh"
if [[ -f "$LIB_PATH" ]]; then
    if ! source "$LIB_PATH"; then
        echo "Fatal Error: Cannot load library '$LIB_PATH'" >&2
        exit 1
    fi
else
    echo "Fatal Error: Cannot find library '$LIB_PATH'" >&2
    exit 1
fi

DEVICE_UTIL_PATH="${TOOLS_DIR}/lib/device_util.sh"
if [[ -f "$DEVICE_UTIL_PATH" ]]; then
    if ! source "$DEVICE_UTIL_PATH"; then
        echo "Fatal Error: Cannot load library '$DEVICE_UTIL_PATH'" >&2
        exit 1
    fi
else
    echo "Fatal Error: Cannot find library '$DEVICE_UTIL_PATH'" >&2
    exit 1
fi

WORKSPACE_DIR="$( dirname "$TOOLS_DIR" )"
RUN_ID=$(date +%Y%m%d_%H%M%S)

# Default Options
JSON_FILE=""
OUT_DIR="${SCRIPT_DIR}/out"
REPORTS_DIR="${SCRIPT_DIR}/reports"
DRY_RUN=false
KEEP_DEVICE=false
FAIL_FAST=false
FAIL_FAST_ABORTED=false
REUSE_DEVICE=false
RESUME=false
RESUME_FROM=""
SKIP_INITIAL_FLASH=false
DEVICE_STATE_FILE="${OUT_DIR}/.matrix_active_devices"
JOB_FILTER=""
TEST_SUITE_OVERRIDE=""
SERIAL_OVERRIDE=""

# Trap for cleaning up temporary files on exit/interrupt
CVD_SERIAL_FILE=""
ATEST_LOG_FILE=""



function generate_config_template() {
    cat << 'EOF'
{
  "_comment": "Template for build_matrix_runner.sh",
  "global_config": {
    "test_suite": "vts_ltp_test_x86_64"
  },
  "jobs": [
    {
      "job_id": "example_virtual_device",
      "display_name": "Cuttlefish with Mainline Platform & GKI",
      "device_type": "virtual",
      "_comment_device": "device_type MUST be 'virtual' or 'physical'",
      "builds": {
        "pb": {
          "branch": "aosp-main",
          "target": "aosp_cf_x86_64_phone-trunk_staging-userdebug",
          "build_id": "latest"
        },
        "kb": {
          "branch": "aosp_kernel-common-android15-6.6",
          "target": "kernel_x86_64",
          "build_id": "11223344"
        }
      }
    },
    {
      "job_id": "example_physical_device",
      "device_type": "physical",
      "serial_port": "127.0.0.1:40465",
      "_comment_serial": "serial_port is required for physical devices unless passed via -s",
      "builds": {
        "pb": {
          "branch": "aosp-main",
          "target": "aosp_panther-userdebug",
          "build_id": "latest"
        }
      }
    }
  ]
}
EOF
}

function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Run ATest against a matrix of device builds specified in a JSON file."
    echo ""
    echo "Options:"
    echo "  --generate-config          Print a template JSON configuration to stdout and exit"
    echo "  -c, --config <file>        Path to the JSON configuration file"
    echo "  -od, --output-dir <dir>    Directory to save reports (default: reports)"
    echo "  -j, --job-id <job_id>      Only run a specific job_id from the JSON config"
    echo "  -t, --test <test_suite>    Override the test suite specified in the JSON config"
    echo "  -s, --serial-number <sn>   Override or provide the serial number for physical devices"
    echo "  --dry-run                  Parse config and print jobs without actually launching devices or running tests"
    echo "  --keep-device, --no-teardown Do not delete virtual devices after tests complete or fail"
    echo "  --reuse-device             Reuse an existing virtual device if one was previously kept alive (implies --keep-device)"
    echo "  --fail-fast                Abort the entire matrix run if any job fails (by default, it keeps going)"
    echo ""
    echo "Stateful Resume Options:"
    echo "  --resume                   Automatically resume the matrix from the last interrupted or failed job."
    echo "                             This will reuse the same RUN_ID (so logs are grouped together) and"
    echo "                             skip jobs that are already marked as PASSED."
    echo "  --resume-from <job_id>     Skip all jobs before <job_id> and start execution from <job_id>."
    echo "                             If no --run-id is provided, it automatically loads the latest RUN_ID."
    echo "  --run-id <id>              Manually specify a RUN_ID (e.g., 20260905_123456) for logs and reports."
    echo "                             Usually combined with --resume-from."
    echo "  --skip-initial-flash       Skip the 'flash_device.sh' step ONLY for the first executed physical device job."
    echo "                             Useful when resuming a job on a device that is already fully flashed,"
    echo "                             preventing the need to wait for reflashing."
    echo ""
    echo "  -h, --help                 Display this help message"
}

function abort() {
    local message="$1"
    local exit_code="${2:-1}"
    # log_error returns non-zero; swallow it so 'set -e' does not pre-empt the
    # explicit exit below and clobber the intended exit code.
    log_error "$message" "$exit_code" 2 || true
    exit "$exit_code"
}

# Records a job failure without aborting the matrix run. Frame offset 2 makes
# the log point at the real call site instead of this wrapper.
function fail_job() {
    log_error "$1" "${2:-}" 2 || true
    JOB_FAILED=true
}

function cleanup_temp_files() {
    [[ -n "${CVD_SERIAL_FILE:-}" && -f "$CVD_SERIAL_FILE" ]] && rm -f "$CVD_SERIAL_FILE"
    [[ -n "${ATEST_LOG_FILE:-}" && -f "$ATEST_LOG_FILE" ]] && rm -f "$ATEST_LOG_FILE"
    return 0
}

function parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            --generate-config)
                generate_config_template
                exit 0
                ;;
            -c|--config)
                shift
                JSON_FILE="$1"
                shift
                ;;
            -od|--output-dir)
                shift
                REPORTS_DIR="$1"
                shift
                ;;
            -j|--job-id)
                shift
                JOB_FILTER="$1"
                shift
                ;;
            -t|--test)
                shift
                TEST_SUITE_OVERRIDE="$1"
                shift
                ;;
            -s|--serial-number)
                shift
                SERIAL_OVERRIDE="$1"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --keep-device|--no-teardown)
                KEEP_DEVICE=true
                shift
                ;;
            --reuse-device)
                REUSE_DEVICE=true
                KEEP_DEVICE=true
                shift
                ;;
            --fail-fast)
                FAIL_FAST=true
                shift
                ;;
            --resume)
                RESUME=true
                shift
                ;;
            --resume-from)
                shift
                RESUME_FROM="$1"
                shift
                ;;
            --run-id)
                shift
                USER_RUN_ID="$1"
                shift
                ;;
            --skip-initial-flash)
                SKIP_INITIAL_FLASH=true
                shift
                ;;
            *)
                log_error "Unsupported flag: $1" || true
                print_help
                exit 1
                ;;
        esac
    done
}

# Set traps for cleanup right before starting execution
trap cleanup_temp_files EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Dependencies check
if ! check_command "jq"; then
    abort "jq is required but not installed."
fi

parse_args "$@"

if [[ "$RESUME" == "true" && -n "$RESUME_FROM" ]]; then
    abort "Error: --resume and --resume-from are mutually exclusive. Use --resume for automatic continuation, OR --resume-from <job_id> for manual override."
fi

if [[ -z "$JSON_FILE" ]]; then
    abort "No JSON config specified. Please use -c <file>. Run with --generate-config to see a template."
fi

if [[ ! -f "$JSON_FILE" ]]; then
    abort "JSON file not found: $JSON_FILE"
fi

USER_RUN_ID="${USER_RUN_ID:-}"
STATE_FILE="${OUT_DIR}/.run_state_$(basename "${JSON_FILE}" .json)"
declare -A JOB_STATUS_MAP=()
declare -i TOTAL_SUCCESS=0
declare -i TOTAL_COMPLETED_WITH_FAILURES=0
declare -i TOTAL_ERROR=0

if [[ "$RESUME" == "true" || -n "$RESUME_FROM" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
        log_info "Loading state from $STATE_FILE..."
        while IFS='=' read -r key value; do
            if [[ "$key" == "RUN_ID" ]]; then
                SAVED_RUN_ID="$value"
            elif [[ "$key" == "ABORTED_ON" ]]; then
                SAVED_ABORTED_ON="$value"
            elif [[ "$key" == JOB_STATUS_* ]]; then
                job_name="${key#JOB_STATUS_}"
                JOB_STATUS_MAP["$job_name"]="$value"
            fi
        done < "$STATE_FILE"
        if [[ "$RESUME" == "true" && -z "$RESUME_FROM" && -n "${SAVED_ABORTED_ON:-}" ]]; then
            log_info "Found previously aborted job: $SAVED_ABORTED_ON. Will resume from there."
            RESUME_FROM="$SAVED_ABORTED_ON"
        fi
        if [[ -z "$USER_RUN_ID" && -n "${SAVED_RUN_ID:-}" ]]; then
            RUN_ID="$SAVED_RUN_ID"
        fi
    else
        log_warn "State file $STATE_FILE not found. Cannot resume."
    fi
fi

if [[ -n "$USER_RUN_ID" ]]; then
    RUN_ID="$USER_RUN_ID"
fi

mkdir -p "$(dirname "$STATE_FILE")"
if [[ "$RESUME" != "true" && -z "$RESUME_FROM" ]]; then
    # Fresh run, clear state file
    > "$STATE_FILE"
fi
sed -i "/^RUN_ID=/d" "$STATE_FILE" 2>/dev/null || true
echo "RUN_ID=$RUN_ID" >> "$STATE_FILE"

# Create up-front so the reporter still works when every job fails before testing.
mkdir -p "${REPORTS_DIR}/${RUN_ID}"

log_info "Using configuration from $JSON_FILE"
log_info "Run ID: $RUN_ID"

TEST_SUITE="$TEST_SUITE_OVERRIDE"
if [[ -z "$TEST_SUITE" ]]; then
    TEST_SUITE=$(jq -r '.global_config.test_suite // empty' "$JSON_FILE")
    if [[ -z "$TEST_SUITE" ]]; then
        TEST_SUITE="vts_ltp_test_x86_64"
    fi
fi
log_info "Test Suite: $TEST_SUITE"

# Get number of jobs
NUM_JOBS=$(jq '.jobs | length' "$JSON_FILE")

# Pre-flight validation for --resume-from
if [[ -n "$RESUME_FROM" ]]; then
    found_target=false
    for (( i=0; i<$NUM_JOBS; i++ )); do
        PRE_JOB_ID=$(jq -r ".jobs[$i].job_id // empty" "$JSON_FILE")
        if [[ "$PRE_JOB_ID" == "$RESUME_FROM" ]]; then
            found_target=true
            break
        fi
        pre_status="${JOB_STATUS_MAP[$PRE_JOB_ID]:-}"
        if [[ "$pre_status" != "SUCCESS" && "$pre_status" != "COMPLETED_WITH_FAILURES" ]]; then
            abort "Error: Cannot resume from '$RESUME_FROM'. Previous job '$PRE_JOB_ID' is incomplete or has status '$pre_status'. Please run sequentially or remove '$PRE_JOB_ID' from config."
        fi
    done
    if [[ "$found_target" == "false" ]]; then
        abort "Error: --resume-from target '$RESUME_FROM' not found in configuration jobs."
    fi
fi


for (( i=0; i<$NUM_JOBS; i++ )); do
    JOB_ID=$(jq -r ".jobs[$i].job_id // empty" "$JSON_FILE")

    if [[ -n "$RESUME_FROM" ]]; then
        if [[ "$JOB_ID" != "$RESUME_FROM" ]]; then
            status="${JOB_STATUS_MAP[$JOB_ID]:-}"
            if [[ "$status" == "SUCCESS" ]]; then
                TOTAL_SUCCESS+=1
            elif [[ "$status" == "COMPLETED_WITH_FAILURES" ]]; then
                TOTAL_COMPLETED_WITH_FAILURES+=1
            elif [[ "$status" == "ERROR" ]]; then
                TOTAL_ERROR+=1
            fi
            log_info "Skipping Job $JOB_ID (waiting for RESUME_FROM=$RESUME_FROM)..."
            continue
        else
            log_info "Reached RESUME_FROM target: $JOB_ID. Resuming execution."
            RESUME_FROM=""
        fi
    elif [[ "$RESUME" == "true" ]]; then
        status="${JOB_STATUS_MAP[$JOB_ID]:-}"
        if [[ "$status" == "SUCCESS" || "$status" == "COMPLETED_WITH_FAILURES" ]]; then
            log_info "Skipping Job $JOB_ID because it previously completed ($status)."
            if [[ "$status" == "SUCCESS" ]]; then
                TOTAL_SUCCESS+=1
            else
                TOTAL_COMPLETED_WITH_FAILURES+=1
            fi
            continue
        fi
    fi

    if [[ -n "$JOB_FILTER" && "$JOB_ID" != "$JOB_FILTER" ]]; then
        continue
    fi

    DEVICE_TYPE=$(jq -r ".jobs[$i].device_type // empty" "$JSON_FILE")
    DISPLAY_NAME=$(jq -r ".jobs[$i].display_name // empty" "$JSON_FILE")

    echo "==========================================================="
    log_info "Starting Job: $JOB_ID ($DISPLAY_NAME)"
    log_info "Device Type: $DEVICE_TYPE"
    echo "==========================================================="

    # Extract pb
    PB_BRANCH=$(jq -r ".jobs[$i].builds.pb.branch // empty" "$JSON_FILE")
    PB_TARGET=$(jq -r ".jobs[$i].builds.pb.target // empty" "$JSON_FILE")
    PB_BUILD_ID=$(jq -r ".jobs[$i].builds.pb.build_id // empty" "$JSON_FILE")
    PB_URL=""
    if [[ -n "$PB_BRANCH" && -n "$PB_TARGET" ]]; then
        PB_URL="ab://${PB_BRANCH}/${PB_TARGET}/${PB_BUILD_ID:-latest}"
    fi

    # Extract kb
    KB_BRANCH=$(jq -r ".jobs[$i].builds.kb.branch // empty" "$JSON_FILE")
    KB_TARGET=$(jq -r ".jobs[$i].builds.kb.target // empty" "$JSON_FILE")
    KB_BUILD_ID=$(jq -r ".jobs[$i].builds.kb.build_id // empty" "$JSON_FILE")
    KB_URL=""
    if [[ -n "$KB_BRANCH" && -n "$KB_TARGET" ]]; then
        KB_URL="ab://${KB_BRANCH}/${KB_TARGET}/${KB_BUILD_ID:-latest}"
    fi

    # Extract vkb (Vendor Kernel Build)
    VKB_BRANCH=$(jq -r ".jobs[$i].builds.vkb.branch // empty" "$JSON_FILE")
    VKB_TARGET=$(jq -r ".jobs[$i].builds.vkb.target // empty" "$JSON_FILE")
    VKB_BUILD_ID=$(jq -r ".jobs[$i].builds.vkb.build_id // empty" "$JSON_FILE")
    VKB_URL=""
    if [[ -n "$VKB_BRANCH" && -n "$VKB_TARGET" ]]; then
        VKB_URL="ab://${VKB_BRANCH}/${VKB_TARGET}/${VKB_BUILD_ID:-latest}"
    fi

    # Extract sb (System Build / GSI Build)
    SB_BRANCH=$(jq -r ".jobs[$i].builds.sb.branch // empty" "$JSON_FILE")
    SB_TARGET=$(jq -r ".jobs[$i].builds.sb.target // empty" "$JSON_FILE")
    SB_BUILD_ID=$(jq -r ".jobs[$i].builds.sb.build_id // empty" "$JSON_FILE")
    SB_URL=""
    if [[ -n "$SB_BRANCH" && -n "$SB_TARGET" ]]; then
        SB_URL="ab://${SB_BRANCH}/${SB_TARGET}/${SB_BUILD_ID:-latest}"
    fi

    LAUNCH_ARGS=()
    if [[ -n "$PB_URL" ]]; then LAUNCH_ARGS+=("-pb" "$PB_URL"); fi
    if [[ -n "$KB_URL" ]]; then LAUNCH_ARGS+=("-kb" "$KB_URL"); fi
    if [[ -n "$VKB_URL" ]]; then LAUNCH_ARGS+=("-vkb" "$VKB_URL"); fi
    if [[ -n "$SB_URL" ]]; then LAUNCH_ARGS+=("-sb" "$SB_URL"); fi

    if [[ -n "$PB_URL" ]]; then log_info "Platform Build: $PB_URL"; fi
    if [[ -n "$KB_URL" ]]; then log_info "Kernel Build: $KB_URL"; fi
    if [[ -n "$VKB_URL" ]]; then log_info "Vendor Kernel Build: $VKB_URL"; fi
    if [[ -n "$SB_URL" ]]; then log_info "System/GSI Build: $SB_URL"; fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would launch $DEVICE_TYPE device and run tests."
        continue
    fi

    SERIAL=""
    JOB_FAILED=false
    TESTS_FAILED=false

    if [[ "$DEVICE_TYPE" == "virtual" ]]; then
        skip_launch=false

        if [[ "$REUSE_DEVICE" == "true" && -f "$DEVICE_STATE_FILE" ]]; then
            saved_serial=$(grep "^${JOB_ID}=" "$DEVICE_STATE_FILE" | cut -d'=' -f2) || true
            if [[ -n "$saved_serial" ]]; then
                log_info "Found saved device for $JOB_ID: $saved_serial. Checking liveness..."
                if adb devices | grep -q -w "${saved_serial}.*device"; then
                    log_info "Device $saved_serial is alive. Skipping launch_cvd.sh."
                    SERIAL="$saved_serial"
                    skip_launch=true
                else
                    log_warn "Saved device $saved_serial is dead or missing. Launching a new one..."
                    sed -i "/^${JOB_ID}=/d" "$DEVICE_STATE_FILE" 2>/dev/null || true
                fi
            fi
        fi

        if [[ "$skip_launch" == "false" ]]; then
            CVD_SERIAL_FILE=$(mktemp)
            log_info "Launching virtual device..."

            set +e
            "${LAUNCH_CVD_SCRIPT}" "${LAUNCH_ARGS[@]}" -so "$CVD_SERIAL_FILE"
            LAUNCH_STATUS=$?
            set -e

            if [[ $LAUNCH_STATUS -ne 0 ]] || [[ ! -f "$CVD_SERIAL_FILE" ]] || [[ ! -s "$CVD_SERIAL_FILE" ]]; then
                fail_job "Failed to obtain Cuttlefish serial number or launch failed."
            else
                SERIAL=$(cat "$CVD_SERIAL_FILE")
                log_info "Obtained CVD Serial: $SERIAL"
                mkdir -p "$(dirname "$DEVICE_STATE_FILE")"
                if [[ -f "$DEVICE_STATE_FILE" ]]; then
                    sed -i "/^${JOB_ID}=/d" "$DEVICE_STATE_FILE" 2>/dev/null || true
                fi
                echo "${JOB_ID}=${SERIAL}" >> "$DEVICE_STATE_FILE"
            fi
            rm -f "$CVD_SERIAL_FILE"
            CVD_SERIAL_FILE=""
        fi
    elif [[ "$DEVICE_TYPE" == "physical" ]]; then
        SERIAL="${SERIAL_OVERRIDE}"
        if [[ -z "$SERIAL" ]]; then
            SERIAL=$(jq -r ".jobs[$i].serial_port // empty" "$JSON_FILE")
        fi
        if [[ -z "$SERIAL" ]]; then
            fail_job "serial_port not defined for physical job $JOB_ID and no -s provided."
        else
            skip_flash=false
            if [[ "$SKIP_INITIAL_FLASH" == "true" ]]; then
                log_info "Skipping flash for physical device $SERIAL (--skip-initial-flash requested)."
                skip_flash=true
                SKIP_INITIAL_FLASH=false # Turn it off after the first use
            fi
            if [[ "$skip_flash" == "false" ]]; then
                log_info "Flashing physical device with serial: $SERIAL..."
                set +e
                "${FLASH_DEVICE_SCRIPT}" -s "$SERIAL" "${LAUNCH_ARGS[@]}"
                LAUNCH_STATUS=$?
                set -e
                if [[ $LAUNCH_STATUS -ne 0 ]]; then
                    fail_job "Flashing physical device failed."
                fi
            fi
        fi
    else
        fail_job "Unknown device type '$DEVICE_TYPE' for job $JOB_ID"
    fi

    if [[ "$JOB_FAILED" == "false" && -n "$SERIAL" ]]; then
        log_info "Initializing device context for $SERIAL..."
        if ! device_util::init "$SERIAL"; then
            fail_job "Failed to initialize device_util for serial $SERIAL"
        else
            adb_serial=$(device_util::get_adb_serial)
            if [[ -z "$adb_serial" ]]; then
                fail_job "Could not resolve ADB serial for device $SERIAL"
            else
                log_info "Running tests on ADB device $adb_serial..."
                ATEST_LOG_FILE=$(mktemp)

                # Run test
                set +e
                "${RUN_TEST_SCRIPT}" --no-force-wifi-connection -ta --no-fail-fast -s "$adb_serial" -t "$TEST_SUITE" 2>&1 | tee "$ATEST_LOG_FILE"
                TEST_STATUS=${PIPESTATUS[0]}
                set -e

                if [[ $TEST_STATUS -ne 0 ]]; then
                    if grep -q -E "Passed: [0-9]+, Failed: [0-9]+" "$ATEST_LOG_FILE"; then
                        log_warn "Tests completed with failures for job $JOB_ID."
                        TESTS_FAILED=true
                    else
                        fail_job "run_test_only.sh crashed or failed to run tests for job $JOB_ID (Exit $TEST_STATUS)."
                    fi
                fi

                # Parse ATest stdout for log directory
                # Expected format: Test logs: /tmp/atest_result_chihsheng/20260901_151720_7bzv8uvp/log
                ATEST_LOG_DIR=$(grep 'Test logs:' "$ATEST_LOG_FILE" | awk '{print $3}' | sed 's|/log$||' | head -n 1)

                REPORT_DEST="${REPORTS_DIR}/${RUN_ID}/${JOB_ID}"
                mkdir -p "$REPORT_DEST"

                log_info "Preserving runner stdout to ${REPORT_DEST}/runner_stdout.log"
                cp "$ATEST_LOG_FILE" "${REPORT_DEST}/runner_stdout.log"

                if [[ -n "$ATEST_LOG_DIR" && -d "$ATEST_LOG_DIR" ]]; then
                    log_info "Copying test logs from $ATEST_LOG_DIR to $REPORT_DEST"
                    cp -r "$ATEST_LOG_DIR"/. "$REPORT_DEST"/
                else
                    log_warn "Could not extract ATest log directory or directory does not exist."
                fi

                rm -f "$ATEST_LOG_FILE"
                ATEST_LOG_FILE=""
            fi
        fi
    fi

    if [[ "$DEVICE_TYPE" == "virtual" ]]; then
        if [[ "$KEEP_DEVICE" == "true" ]]; then
            log_info "Skipping virtual device teardown (--keep-device)."
        else
            log_info "Tearing down virtual device..."
            DELETE_ARGS=("--all")
            if [[ -n "${SERIAL:-}" ]]; then
                ADB_PORT="${SERIAL##*:}"
                if [[ "$ADB_PORT" =~ ^[0-9]+$ ]]; then
                    DELETE_ARGS=("--adb-port" "$ADB_PORT")
                    log_info "Targeting device with adb port: $ADB_PORT"
                else
                    log_warn "Cannot extract port from serial '$SERIAL', falling back to --all"
                fi
            fi

            if check_command "acloud"; then
                acloud delete "${DELETE_ARGS[@]}"
            else
                log_warn "acloud not found in PATH, trying to locate..."
                # Try to find acloud in platform repo if possible, or skip
                ACLOUD_PREBUILT="${WORKSPACE_DIR}/../../prebuilts/asuite/acloud/linux-x86/acloud"
                if [[ -x "$ACLOUD_PREBUILT" ]]; then
                    "$ACLOUD_PREBUILT" delete "${DELETE_ARGS[@]}"
                else
                    log_warn "Could not find acloud binary to delete CVD."
                fi
            fi
        fi
    fi

    if [[ "$JOB_FAILED" == "false" && "$TESTS_FAILED" == "false" ]]; then
        log_info "Job $JOB_ID completed successfully."
        TOTAL_SUCCESS+=1
        sed -i "/^JOB_STATUS_${JOB_ID}=/d" "$STATE_FILE" 2>/dev/null || true
        sed -i "/^ABORTED_ON=/d" "$STATE_FILE" 2>/dev/null || true
        echo "JOB_STATUS_${JOB_ID}=SUCCESS" >> "$STATE_FILE"
    elif [[ "$JOB_FAILED" == "false" && "$TESTS_FAILED" == "true" ]]; then
        log_warn "Job $JOB_ID completed, but some tests failed."
        TOTAL_COMPLETED_WITH_FAILURES+=1
        sed -i "/^JOB_STATUS_${JOB_ID}=/d" "$STATE_FILE" 2>/dev/null || true
        sed -i "/^ABORTED_ON=/d" "$STATE_FILE" 2>/dev/null || true
        echo "JOB_STATUS_${JOB_ID}=COMPLETED_WITH_FAILURES" >> "$STATE_FILE"
    else
        log_error "Job $JOB_ID failed setup or crashed." || true
        TOTAL_ERROR+=1
        sed -i "/^JOB_STATUS_${JOB_ID}=/d" "$STATE_FILE" 2>/dev/null || true
        echo "JOB_STATUS_${JOB_ID}=ERROR" >> "$STATE_FILE"
        # Option B for fail-fast: only abort on ERROR (not COMPLETED_WITH_FAILURES)
        if [[ "$FAIL_FAST" == "true" ]]; then
            sed -i "/^ABORTED_ON=/d" "$STATE_FILE" 2>/dev/null || true
            echo "ABORTED_ON=${JOB_ID}" >> "$STATE_FILE"
            log_error "Aborting entirely due to ERROR in job $JOB_ID (--fail-fast)." || true
            FAIL_FAST_ABORTED=true
            break
        else
            sed -i "/^ABORTED_ON=/d" "$STATE_FILE" 2>/dev/null || true
            log_warn "Continuing to next job (default behavior)."
        fi
    fi
done

echo "==========================================================="
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run completed."
else
    log_info "Matrix Run Summary:"
    log_info "TOTAL SUCCESS: $TOTAL_SUCCESS"
    log_info "TOTAL COMPLETED_WITH_FAILURES: $TOTAL_COMPLETED_WITH_FAILURES"
    log_info "TOTAL ERROR: $TOTAL_ERROR"
    if [[ "$FAIL_FAST_ABORTED" == "true" ]]; then
        log_error "Matrix execution was aborted early due to --fail-fast." || true
    fi
    if [[ $TOTAL_ERROR -eq 0 ]]; then
        if [[ $TOTAL_COMPLETED_WITH_FAILURES -eq 0 ]]; then
            log_info "All executed jobs completed successfully with 0 test failures."
        else
            log_warn "All jobs completed, but some had test failures."
        fi
    else
        log_error "$TOTAL_ERROR jobs encountered infra errors/crashes. Please check logs." || true
    fi
    log_info "Reports are saved in ${REPORTS_DIR}/${RUN_ID}"

    REPORTER_BIN="${TOOLS_DIR}/build_matrix_runner/reporter/venv/bin/matrix-reporter"
    if [[ -x "$REPORTER_BIN" ]]; then
        log_info "Generating Matrix Report..."
        "$REPORTER_BIN" --report-dir "${REPORTS_DIR}/${RUN_ID}" --config "$JSON_FILE" || log_warn "Failed to generate matrix report."
    else
        log_warn "Matrix reporter not found. To enable it, run 'make setup' in the build_matrix_runner directory."
    fi
fi

if [[ "$KEEP_DEVICE" == "true" ]]; then
    log_warn "Virtual devices were kept alive due to --keep-device or --reuse-device."
    log_warn "Please run 'acloud delete --all' manually when you are done to free resources."
fi
echo "==========================================================="

if [[ $TOTAL_ERROR -gt 0 || "$FAIL_FAST_ABORTED" == "true" ]]; then
    exit 1
fi
