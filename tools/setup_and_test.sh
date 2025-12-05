#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

#
# setup_and_test.sh
#
# A standalone script to setup an Android device (Virtual or Physical) with a
# specific, fixed build configuration and run tests against it.
#

# --- Configuration Constants ---
readonly DEFAULT_OUTPUT_DIR="/tmp/setup_and_test_out/$(date +%Y%m%d_%H%M%S)"
readonly -A BUILD_TYPE_MAP=(
    ["pb"]="PLATFORM_BUILD"
    ["kb"]="KERNEL_BUILD"
    ["vkb"]="VENDOR_KERNEL_BUILD"
    ["tb"]="TEST_SUITE_BUILD"
)

# --- Global Variables ---
ACLOUD_OUTPUT_FILE="/tmp/ACLOUD_OUTPUT.tmp"
FILES_TO_CLEANUP=("$ACLOUD_OUTPUT_FILE")
DEVICE_TYPE=""
PLATFORM_BUILD=""
KERNEL_BUILD=""
VENDOR_KERNEL_BUILD=""
SERIAL_NUMBER=""
TEST_NAME=()
TEST_DIR=""
TEST_SUITE_BUILD=""
CACHE_DIR=""
OUTPUT_DIR=""
SKIP_BUILD=false
RESTORE_GIT_STATE=false

# Mappings for execution
declare -A ID_TYPES
declare -A TREE_PATHS
declare -A PROJECTS
declare -A COMMITS_TO_TEST_MAP
declare -A ORIGINAL_GIT_STATES # Stores original branch/commit before checkout

# --- Library Import ---
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
LIB_PATH="${SCRIPT_DIR}/common_lib.sh"
DEVICE_UTIL_PATH="${SCRIPT_DIR}/lib/device_util.sh"

# Check for libraries (Adjust paths if libs are in same dir or ./lib)
if [[ ! -f "$LIB_PATH" ]]; then
    echo "FATAL ERROR: Cannot find required library 'common_lib.sh'" >&2
    exit 1
fi
if ! . "$LIB_PATH"; then
    echo "FATAL ERROR: Failed to source library '$LIB_PATH'" >&2
    exit 1
fi

if [[ ! -f "$DEVICE_UTIL_PATH" ]]; then
    fail_error "FATAL ERROR: Cannot find required library 'device_util.sh'"
fi
if ! . "$DEVICE_UTIL_PATH"; then
    fail_error "FATAL ERROR: Failed to source library '$DEVICE_UTIL_PATH'"
fi

# --- Scripts ---
readonly LAUNCH_CVD_SCRIPT="${SCRIPT_DIR}/launch_cvd.sh"
readonly FLASH_DEVICE_SCRIPT="${SCRIPT_DIR}/flash_device.sh"
readonly RUN_TEST_SCRIPT="${SCRIPT_DIR}/run_test_only.sh"
readonly FETCH_ARTIFACT_SCRIPT="${SCRIPT_DIR}/fetch_artifact.sh"

# --- Helper Functions ---
function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Setup an Android device with specific builds and run tests."
    echo "Accepts fixed commits, local paths, or AB URLs. Does NOT support ranges/lists."
    echo ""
    echo "Exit Codes:"
    echo "  0: Success (Tests Passed)"
    echo "  1: Test Failure"
    echo "  2: Setup/Infrastructure Failure (Build, Flash, Boot)"
    echo "  3: Argument/Validation Error"
    echo ""
    echo "Options:"
    echo "  -pb,  --platform-build <string>    Platform build definition."
    echo "  -kb,  --kernel-build <string>      Kernel build definition."
    echo "  -vkb, --vendor-kernel-build <string> Vendor kernel build definition."
    echo "  -tb,  --test-suite-build <string>  Test suite definition (AB URL, local path, or fixed commit)."
    echo "  -t,   --test <name>                [Required] Test name(s) to run."
    echo "  -s,   --serial-number <serial>     Physical device serial. Default: Cuttlefish."
    echo "  -od,  --output-dir <path>          Directory for logs/artifacts. Default: /tmp/setup_and_test_out/<timestamp>"
    echo "  -cd,  --cache-dir <path>           Directory for cached downloads."
    echo "  --restore                          Restore git repositories to their original state after testing."
    echo "  --skip-build                       Skip the build/flash step, just run tests."
    echo "  -h,   --help                       Display this message."
    echo ""
    echo "Examples:"
    echo "  $0 -pb ab://git_main/target/12345 -kb ~/kernel/common:a1b2c3d -t CtsExampleTest"
}

function fail_error() {
    local message="$1"
    local exit_code="${2:-3}" # Default to 3 (Validation Error) if not specified
    log_error "$message" "$exit_code" 2
    exit "$exit_code"
}

function restore_all_git_states() {
    if [[ "$RESTORE_GIT_STATE" != "true" ]]; then
        return 0
    fi

    log_info "Restoring all modified git repositories to their original state..."
    for type_code in "${!ORIGINAL_GIT_STATES[@]}"; do
        local original_state="${ORIGINAL_GIT_STATES[$type_code]}"
        if [[ -z "$original_state" ]]; then
            continue
        fi

        local project_path="${TREE_PATHS[$type_code]}/${PROJECTS[$type_code]}"
        if [[ -d "$project_path/.git" ]]; then
            log_info "Restoring project '$project_path' to '$original_state'..."
            # Capture output to avoid spamming unless error
            if ! (cd "$project_path" && git checkout "$original_state" &>/dev/null); then
                log_error "Failed to restore project '$project_path' to '$original_state'."
            fi
        fi
    done
}

function cleanup() {
    restore_all_git_states

    # Clean up temp files
    for f in "${FILES_TO_CLEANUP[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
        fi
    done
}

function parse_args() {
    while test $# -gt 0; do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            -od|--output-dir)
                shift
                OUTPUT_DIR="$1"
                shift
                ;;
            -pb|--platform-build)
                shift
                PLATFORM_BUILD="$1"
                shift
                ;;
            -kb|--kernel-build)
                shift
                KERNEL_BUILD="$1"
                shift
                ;;
            -vkb|--vendor-kernel-build)
                shift
                VENDOR_KERNEL_BUILD="$1"
                shift
                ;;
            -s|--serial-number)
                shift
                SERIAL_NUMBER="$1"
                shift
                ;;
            -t|--test)
                shift
                TEST_NAME+=("$1")
                shift
                ;;
            -td|--test-dir|-tb|--test-suite-build)
                shift
                TEST_SUITE_BUILD="$1"
                shift
                ;;
            -cd|--cache-dir)
                shift
                CACHE_DIR="$1"
                shift
                ;;
            --restore)
                RESTORE_GIT_STATE=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            *)
                fail_error "Unsupported flag: $1"
                ;;
        esac
    done

    if [[ ${#TEST_NAME[@]} -eq 0 ]]; then
         fail_error "At least one test must be specified with -t."
    fi

    # Set Default Output Dir if not provided
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
    fi
    # Create output dir
    mkdir -p "$OUTPUT_DIR" || fail_error "Failed to create output directory: $OUTPUT_DIR"
    OUTPUT_DIR=$(realpath "$OUTPUT_DIR")

    log_info "Output Directory: $OUTPUT_DIR"
}

function parse_change_string() {
    local build_str="$1"
    local -n tree_path_ref="$2"
    local -n project_ref="$3"
    local -n commits_ref="$4"
    local -n type_ref="$5"

    # Check for ab:// URL
    if [[ "$build_str" == ab://* ]]; then
        type_ref="ab"
        commits_ref=("$build_str")
        return 0
    fi

    # Check for local path without project/commit part (fixed local tree)
    if [[ ! "$build_str" == *:* ]]; then
        if [[ -d "$build_str" ]]; then
            type_ref="local"
            commits_ref=("$build_str")
            return 0
        else
            fail_error "Build string is not a valid directory and not a known format: $build_str"
        fi
    fi

    # It's a format with a colon: path/to/project:commit
    local path_part="${build_str%%:*}"
    local commit_part="${build_str#*:}"

    # Expand tilde
    local expanded_path="${path_part/#\~/$HOME}"

    # Resolve to absolute path to verify existence and find root
    if [[ ! -d "$expanded_path" ]]; then
        fail_error "Path does not exist: $expanded_path"
    fi

    local abs_path
    abs_path=$(cd "$expanded_path" && pwd -P)

    # Use find_repo_root to split Tree Root and Project Path
    local repo_root
    if ! repo_root=$(find_repo_root "$abs_path"); then
        fail_error "Could not find Android Tree Root (.repo) for: $abs_path"
    fi

    tree_path_ref="$repo_root"

    # Project path is the remainder (abs_path - repo_root)
    # Remove prefix "$repo_root/"
    if [[ "$abs_path" == "$repo_root" ]]; then
        fail_error "Path cannot be the repo root itself. Must be a project."
    fi
    project_ref="${abs_path#$repo_root/}"

    # STRICT VALIDATION: Fail on range or list
    if [[ "$commit_part" == *","* ]]; then
        fail_error "Error: List format (comma-separated) is NOT supported in this script. Use find_change_breakage.sh for bisection."
    elif [[ "$commit_part" == *"-"* ]]; then
        fail_error "Error: Range format (hyphen-separated) is NOT supported in this script. Use find_change_breakage.sh for bisection."
    elif [[ -n "$commit_part" ]]; then
        type_ref="fixed_commit"
        commits_ref=("$commit_part")
    else
        fail_error "Invalid format. Commit hash missing for: $build_str"
    fi
    return 0
}

function validate_args() {
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local build_value="${!var_name}"
        if [[ -z "$build_value" ]]; then
            continue
        fi

        local tree_path project
        local -a commits=()
        local id_type=""
        parse_change_string "$build_value" tree_path project commits id_type

        ID_TYPES[$type_code]="$id_type"

        if [[ "$id_type" == "fixed_commit" ]]; then
            log_info "Validating git path for '$type_code'..."
            TREE_PATHS[$type_code]="$tree_path"
            PROJECTS[$type_code]="$project"
            COMMITS_TO_TEST_MAP[$type_code]="${commits[0]}"

            if [[ ! -d "$tree_path" ]]; then
                fail_error "[$type_code] Android source tree path does not exist: $tree_path"
            fi

            local full_project_path="${tree_path}/${project}"
            if [[ ! -d "$full_project_path/.git" ]]; then
                fail_error "[$type_code] Project path is not a git repository: $full_project_path"
            fi

            # Verify commit exists
            if ! (cd "$full_project_path" && git cat-file -e "${commits[0]}" &>/dev/null); then
                fail_error "[$type_code] Commit ID '${commits[0]}' does not exist in project '$project'."
            fi
        fi
    done
}

function determine_device_type() {
    local serial="$1"
    if [[ -z "$serial" ]]; then
        echo "VIRTUAL"
    else
        echo "PHYSICAL"
    fi
}

function lock_configuration() {
    # Locks configuration variables to be Read-Only.
    readonly DEVICE_TYPE
    readonly PLATFORM_BUILD
    readonly KERNEL_BUILD
    readonly VENDOR_KERNEL_BUILD
    readonly SERIAL_NUMBER
    readonly TEST_SUITE_BUILD
    readonly CACHE_DIR
    readonly OUTPUT_DIR
    readonly SKIP_BUILD
    readonly RESTORE_GIT_STATE
    readonly -A ID_TYPES
    readonly -A TREE_PATHS
    readonly -A PROJECTS
    readonly -A COMMITS_TO_TEST_MAP
}

function git_get_current_head() {
    local project_path="$1"
    (cd "$project_path" && git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse HEAD)
}

function git_hard_checkout() {
    local project_path="$1"
    local commit_hash="$2"

    log_info "Checking out commit '$commit_hash' in '$project_path'..."
    if ! (cd "$project_path" && git checkout "$commit_hash"); then
        fail_error "Failed to checkout commit '$commit_hash' in '$project_path'."
    fi
}

# --- Test Suite Logic (Reused) ---
function get_test_suite_base_dir() {
    if [[ -n "$CACHE_DIR" ]]; then
        echo "$(realpath "$CACHE_DIR")"
    else
        echo "/tmp/bisect_changes_cache"
    fi
}

function resolve_latest_build_id() {
    local branch="$1"
    local target="$2"
    local -n _resolved_id_ref="$3"

    log_info "Build ID is 'latest'. Resolving to specific BID..."

    local build_info_filename="BUILD_INFO"
    local build_info_path="${OUTPUT_DIR}/${build_info_filename}"
    local build_info_url="ab://${branch}/${target}/latest/${build_info_filename}"

    # Download BUILD_INFO to OUTPUT_DIR
    pushd "$OUTPUT_DIR" >/dev/null || fail_error "Failed to pushd to $OUTPUT_DIR"
    if ! "$FETCH_ARTIFACT_SCRIPT" "$build_info_url"; then
        popd >/dev/null
        fail_error "Failed to download BUILD_INFO to resolve 'latest'."
    fi
    popd >/dev/null

    if [[ ! -f "$build_info_path" ]]; then
        fail_error "BUILD_INFO file not found at $build_info_path"
    fi

    FILES_TO_CLEANUP+=("$build_info_path")

    local resolved_bid
    resolved_bid=$(awk -F'"' '/"bid"/{print $4}' "$build_info_path")

    if [[ -z "$resolved_bid" ]]; then
        fail_error "Failed to parse 'bid' from BUILD_INFO file."
    fi

    log_info "Resolved 'latest' to Build ID: $resolved_bid"
    _resolved_id_ref="$resolved_bid"
}

function prepare_test_suite() {
    local locator="$TEST_SUITE_BUILD"
    if [[ -z "$locator" ]]; then
        return 0
    fi

    log_info "Preparing test suite: $locator"

    if [[ "$locator" == ab://* ]]; then
        # Reuse fetch/unzip logic via cache
        local branch target build_id filename

        if ! parse_ab_url "$locator" branch target build_id; then
            fail_error "Could not parse test suite URL: $locator"
        fi

        if [[ "$build_id" == "latest" ]]; then
            resolve_latest_build_id "$branch" "$target" build_id
        fi

        filename="${locator##*/}"

        local base_dir
        base_dir=$(get_test_suite_base_dir)
        local suite_path="${base_dir}/${branch}/${target}/${build_id}"

        # Check cache
        local unzipped_dir
        if [[ -d "$suite_path" ]]; then
            unzipped_dir=$(find "$suite_path" -mindepth 1 -maxdepth 1 -type d)
            if [[ -n "$unzipped_dir" && -d "$unzipped_dir" ]]; then
                log_info "Found cached test suite: $unzipped_dir"
                TEST_DIR="$unzipped_dir"
                return 0
            fi
        fi

        # Download
        mkdir -p "$suite_path" || fail_error "Could not create dir: $suite_path"
        pushd "$suite_path" >/dev/null || exit 1

        # Construct the specific URL using the resolved ID
        local specific_url="ab://${branch}/${target}/${build_id}/${filename}"
        log_info "Downloading artifact: $specific_url"

        "$FETCH_ARTIFACT_SCRIPT" "$specific_url"
        if (( $? != 0 )); then
            popd >/dev/null
            fail_error "Failed to download test suite."
        fi
        popd >/dev/null

        if [[ ! -f "${suite_path}/${filename}" ]]; then
            fail_error "Downloaded file not found: ${suite_path}/${filename}"
        fi

        log_info "Unzipping test suite..."
        unzip -q "${suite_path}/${filename}" -d "${suite_path}" || fail_error "Failed to unzip."
        rm -f "${suite_path}/${filename}"

        unzipped_dir=$(find "$suite_path" -mindepth 1 -maxdepth 1 -type d)
        TEST_DIR="$unzipped_dir"

    elif [[ "${ID_TYPES[tb]}" == "fixed_commit" ]]; then
        # Orchestrate checkout for Test Suite
        local path="${TREE_PATHS[tb]}/${PROJECTS[tb]}"
        local commit="${COMMITS_TO_TEST_MAP[tb]}"

        if [[ -z "${ORIGINAL_GIT_STATES[tb]}" ]]; then
            ORIGINAL_GIT_STATES[tb]="$(git_get_current_head "$path")"
            log_info "Saved original git state for tb: ${ORIGINAL_GIT_STATES[tb]}"
        fi

        git_hard_checkout "$path" "$commit"
        TEST_DIR="${TREE_PATHS[tb]}"
    else
        # Local path
        TEST_DIR="$locator"
    fi

    if [[ ! -d "$TEST_DIR" ]]; then
        fail_error "Test suite directory is invalid: $TEST_DIR"
    fi
    TEST_DIR=$(realpath "$TEST_DIR")
}

# --- Main Execution Logic ---

function setup_and_run() {
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "fixed_commit" ]]; then
            local path="${TREE_PATHS[$type_code]}/${PROJECTS[$type_code]}"
            local commit="${COMMITS_TO_TEST_MAP[$type_code]}"

            if [[ -z "${ORIGINAL_GIT_STATES[$type_code]}" ]]; then
                ORIGINAL_GIT_STATES[$type_code]="$(git_get_current_head "$path")"
                log_info "Saved original git state for $type_code: ${ORIGINAL_GIT_STATES[$type_code]}"
            fi

            git_hard_checkout "$path" "$commit"
        fi
    done

    prepare_test_suite

    local -a setup_cmd_array=()
    if [[ "$DEVICE_TYPE" == "PHYSICAL" ]]; then
        setup_cmd_array=("$FLASH_DEVICE_SCRIPT" "-s" "$SERIAL_NUMBER")
    else
        setup_cmd_array=("$LAUNCH_CVD_SCRIPT")
    fi

    # Add build args
    for type_code in pb kb vkb; do
        local arg_val=""
        # If it's a git type (fixed_commit), pass the Tree Path
        if [[ "${ID_TYPES[$type_code]}" == "fixed_commit" ]]; then
            arg_val="${TREE_PATHS[$type_code]}"
        else
            # ab:// or local path, pass as is
            local var_name="${BUILD_TYPE_MAP[$type_code]}"
            arg_val="${!var_name}"
        fi

        if [[ -n "$arg_val" ]]; then
            setup_cmd_array+=("-$type_code" "$arg_val")
        fi
    done

    if "$SKIP_BUILD"; then
        setup_cmd_array+=("--skip-build")
    fi

    log_info "Executing device setup: ${setup_cmd_array[*]}"

    local setup_status=0
    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        # We need to capture stdout to find the virtual serial
        unbuffer "${setup_cmd_array[@]}" | tee "$ACLOUD_OUTPUT_FILE"
        setup_status=${PIPESTATUS[0]}
    else
        "${setup_cmd_array[@]}"
        setup_status=$?
    fi

    if (( setup_status != 0 )); then
        fail_error "Device setup failed." 2
    fi

    # 4. Run Tests
    run_tests_on_device
}

function run_tests_on_device() {
    local input_serial_to_use="$SERIAL_NUMBER"

    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        if [[ -f "$ACLOUD_OUTPUT_FILE" ]]; then
            input_serial_to_use=$(grep -oP "ANDROID_SERIAL=\K[\.0-9:]+" "$ACLOUD_OUTPUT_FILE")
        fi
        if [[ -z "$input_serial_to_use" ]]; then
             fail_error "Could not determine virtual device serial from output." 2
        fi
    fi

    log_info "Initializing device interactions for serial: $input_serial_to_use"
    if ! device_util::init "$input_serial_to_use"; then
        fail_error "Failed to initialize device utility." 2
    fi

    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        device_util::wait_for_boot_complete || fail_error "Device failed to boot." 2
    else
        device_util::unlock_screen || fail_error "Failed to unlock screen." 2
        device_util::skip_setup_wizard || fail_error "Failed to skip setup wizard." 2
    fi

    local adb_serial
    adb_serial=$(device_util::get_adb_serial)

    # Ensure test logs dir exists
    local logs_dir="${OUTPUT_DIR}/test_logs"
    mkdir -p "$logs_dir"

    local -a test_cmd=("$RUN_TEST_SCRIPT" "-td" "$TEST_DIR" "-tl" "$logs_dir")
    test_cmd+=("-s" "$adb_serial")

    for test in "${TEST_NAME[@]}"; do
        test_cmd+=("-t" "$test")
    done

    log_info "Executing test command: ${test_cmd[*]}"
    "${test_cmd[@]}"
    local test_status=$?

    if (( test_status == 0 )); then
        log_info "Tests PASSED."
        exit 0
    else
        fail_error "Tests FAILED." 1
    fi
}

function main() {
    trap cleanup EXIT

    check_commands_available "unzip" "git" "repo" "unbuffer" || fail_error "Missing required commands."

    parse_args "$@"
    validate_args

    DEVICE_TYPE=$(determine_device_type "$SERIAL_NUMBER")

    lock_configuration

    setup_and_run
}

main "$@"