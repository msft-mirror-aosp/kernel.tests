#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

#
# setup_and_test.sh
#
# A standalone script to setup an Android device (Virtual or Physical) with a
# specific, fixed build configuration and run tests against it.
#

# --- Configuration Constants ---
readonly DEFAULT_TEST_RETRY=2
readonly DEFAULT_SETUP_RETRY=2
readonly DEFAULT_DOWNLOAD_RETRY=2
readonly -A BUILD_TYPE_MAP=(
    ["pb"]="PLATFORM_BUILD"
    ["sb"]="GSI_BUILD"
    ["kb"]="KERNEL_BUILD"
    ["vkb"]="VENDOR_KERNEL_BUILD"
    ["tb"]="TEST_SUITE_BUILD"
)
readonly -a BUILD_SETUP_ORDER=("pb" "sb" "kb" "vkb")

# --- Global Variables ---
ACLOUD_OUTPUT_FILE="/tmp/ACLOUD_OUTPUT.tmp"
FILES_TO_CLEANUP=("$ACLOUD_OUTPUT_FILE")
DEVICE_TYPE=""
PLATFORM_BUILD=""
GSI_BUILD=""
KERNEL_BUILD=""
VENDOR_KERNEL_BUILD=""
SERIAL_NUMBER=""
TEST_NAME=()
TEST_DIR=""
TEST_SUITE_BUILD=""
OUTPUT_DIR=""
TEST_RETRY=$DEFAULT_TEST_RETRY
SETUP_RETRY=$DEFAULT_SETUP_RETRY
SKIP_BUILD=false
RESTORE_GIT_STATE=false
NON_INTERACTIVE=false
WITH_SETUP_SCRIPT=""
CURRENT_TEST_SUITE_LOCATOR=""

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
    echo "  -kb,  --kernel-build,  -gki,  --gki-build <string>"
    echo "                                     GKI build definition."
    echo "  -sb,  --system-build,  -gsi,  --gsi-build <string>"
    echo "                                     GSI build definition."
    echo "  -vkb, --vendor-kernel-build <string> Vendor kernel build definition."
    echo "  -tb,  --test-suite-build <string>  Test suite definition (AB URL, local path, or fixed commit)."
    echo "  -t,   --test <name>                [Required] Test name(s) to run."
    echo "  -s,   --serial-number <serial>     Physical device serial. Default: Cuttlefish."
    echo "  -od,  --output-dir <path>          Directory for logs/artifacts."
    echo "  -tr,  --test-retry <count>         Retry count for a failed test. Default: ${DEFAULT_TEST_RETRY}."
    echo "  -sr,  --setup-retry <count>        Retry count for failed device setup. Default: ${DEFAULT_SETUP_RETRY}."
    echo "  --restore                          Restore git repositories to their original state after testing."
    echo "  --skip-build                       Skip the build/flash step, just run tests."
    echo "  --non-interactive                  Disable interactive mode on build failures."
    echo "  --with-setup <script_path>         Path to a custom script to run after checkout, before build."
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
    while (( $# > 0 )); do
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
            -sb|-gsi|--system-build|--gsi-build)
                shift
                GSI_BUILD="$1"
                shift
                ;;
            -kb|-gki|--kernel-build|--gki-build)
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
            -tr|--test-retry)
                shift
                TEST_RETRY="$1"
                shift
                ;;
            -sr|--setup-retry)
                shift
                SETUP_RETRY="$1"
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --with-setup)
                shift
                WITH_SETUP_SCRIPT="$1"
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

    if (( ${#TEST_NAME[@]} == 0 )); then
         fail_error "At least one test must be specified with -t."
    fi
    if [[ -n "$WITH_SETUP_SCRIPT" && ! -x "$WITH_SETUP_SCRIPT" ]]; then
        fail_error "The --with-setup script '$WITH_SETUP_SCRIPT' is not executable or does not exist."
    fi
}

function parse_change_string() {
    local build_str="$1"
    local -n tree_path_ref="$2"
    local -n project_ref="$3"
    local -n commits_ref="$4"
    local -n type_ref="$5"

    # Support for "none" to skip flashing specific build artifacts
    if [[ "${build_str,,}" == "none" ]]; then
        type_ref="none"
        commits_ref=("none")
        tree_path_ref="none"
        project_ref="none"
        return 0
    fi

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

function parse_build_string() {
    local build_str="$1"
    local -n branch_ref="$2"
    local -n target_ref="$3"
    local -n ids_ref="$4"
    local -n type_ref="$5"
    local -n filename_ref="$6"

    if [[ "${build_str,,}" == "none" ]]; then
        type_ref="none"
        ids_ref=("none")
        branch_ref="none"
        target_ref="none"
        return $EXIT_SUCCESS
    fi

    if [[ "$build_str" != ab://* ]]; then
        if [[ -d "$build_str" ]]; then
            type_ref="local"
            ids_ref=("$build_str")
            return $EXIT_SUCCESS
        else
            fail_error "Build string is not a valid 'ab://' URL or a local directory: $build_str"
        fi
    fi

    local path_part="${build_str#ab://}"
    local -a parts=()
    local IFS='/'
    read -r -a parts <<< "$path_part"

    if (( ${#parts[@]} < 3 )); then
        fail_error "Malformed ab URL. Expected at least 3 parts: ab://<branch>/<target>/<ids>[/<filename>]. Got: ${build_str}"
    fi

    if [[ -z "${parts[0]}" || -z "${parts[1]}" || -z "${parts[2]}" ]]; then
        fail_error "The branch, target, or ids cannot be empty string. Got: ${build_str}"
    fi

    branch_ref="${parts[0]}"
    target_ref="${parts[1]}"
    local id_part
    id_part=$(echo "${parts[2]}" | tr -d '[:space:]')

    if (( ${#parts[@]} >= 4 )); then
        filename_ref="${parts[3]}"
    fi

    if [[ "$id_part" == *","* ]]; then
        fail_error "Error: List format (comma-separated) is NOT supported in this script."
    elif [[ "$id_part" == *"-"* ]]; then
        fail_error "Error: Range format (hyphen-separated) is NOT supported in this script."
    else
        type_ref="single"
        if ! [[ "$id_part" =~ ^[0-9]+$ || "$id_part" == "latest" ]]; then
            fail_error "Invalid build ID. Must be numeric or 'latest': $id_part"
        fi
        ids_ref=("$id_part")
    fi
    return $EXIT_SUCCESS
}

function get_test_suite_base_dir() {
    echo "$DOWNLOAD_PATH"
}

function handle_test_suite_url() {
    local test_suite_url="$1"
    log_info "Test suite provided as a URL. Preparing for download..."

    local branch target build_id filename
    parse_build_string "$test_suite_url" branch target build_id _ filename

    if [[ "${filename##*.}" != "zip" ]]; then
        fail_error "Test suite filename must be a .zip file. Got: ${filename}"
    fi

    local base_dir
    base_dir=$(get_test_suite_base_dir)

    local suite_path="${base_dir}/${branch}/${target}/${build_id}"
    local download_success=false
    for i in $(seq 1 "$DEFAULT_DOWNLOAD_RETRY"); do
        "$FETCH_ARTIFACT_SCRIPT" "$test_suite_url"
        if (( $? == 0 )) && [[ -f "${suite_path}/${filename}" ]]; then
            download_success=true
            break
        fi
        log_warn "Download failed (Attempt ${i}/${DEFAULT_DOWNLOAD_RETRY}). Retrying..."
        sleep 10
    done

    if ! "$download_success"; then
        fail_error "Failed to download test suite '${filename}'."
    fi

    log_info "unzipping file: ${filename}..."
    unzip -q "${suite_path}/${filename}" -d "${suite_path}" || fail_error "Failed to unzip file."

    local unzipped_root_dir
    unzipped_root_dir=$(find "$suite_path" -mindepth 1 -maxdepth 1 -type d)
    TEST_DIR="$unzipped_root_dir"

    if [[ -z "$TEST_DIR" || ! -d "$TEST_DIR" ]]; then
        fail_error "Test suite directory could not be prepared correctly."
    fi

    TEST_DIR=$(realpath "$TEST_DIR")
    log_info "Test suite is ready at: ${TEST_DIR}"
}

function prepare_test_suite() {
    local required_locator="$1"

    log_info "Checking for required test suite: $required_locator"

    if [[ "$required_locator" != ab://* ]]; then
        TEST_DIR="$required_locator"
        return $EXIT_SUCCESS
    fi

    local branch target build_id filename
    parse_build_string "$required_locator" branch target build_id _ filename

    if [[ "${build_id[0]}" == "latest" ]]; then
        log_info "Resolving 'latest' build ID for test suite..."
        local resolved_id
        if ! resolved_id=$(query_latest_build_id "$branch" "$target"); then
            fail_error "Failed to query the latest build ID for ${branch}/${target}"
        fi
        if [[ -z "$resolved_id" ]]; then
            fail_error "Queried latest build ID is empty for ${branch}/${target}"
        fi
        log_info "Resolved 'latest' to build ID: $resolved_id"
        build_id[0]="$resolved_id"
        required_locator="ab://${branch}/${target}/${resolved_id}/${filename}"
    fi

    local base_dir
    base_dir=$(get_test_suite_base_dir)

    local suite_base_path="${base_dir}/${branch}/${target}/${build_id[0]}"
    if [[ -d "$suite_base_path" ]]; then
        local unzipped_dir
        unzipped_dir=$(find "$suite_base_path" -mindepth 1 -maxdepth 1 -type d)
        if [[ -n "$unzipped_dir" && -d "$unzipped_dir" ]]; then
            log_info "Found existing test suite in cache: $unzipped_dir"
            TEST_DIR="$unzipped_dir"
            return $EXIT_SUCCESS
        fi
    fi

    log_info "Test suite not found in cache. Downloading..."
    handle_test_suite_url "$required_locator"
}

function enter_interactive_fix_mode() {
    local prompt_message="$1"
    if "$NON_INTERACTIVE"; then
        log_error "${prompt_message} Failed in non-interactive mode."
        return 5
    fi

    local rv=5
    cat <<-EOF 1>&2
    ${YELLOW}${prompt_message}${END}
    Spawning a new shell.
    You can attempt to fix the issue (e.g., resolve merge conflicts).
    Once done, exit this shell with one of the following codes:
      ${GREEN}exit 0${END}:     Retry the operation.
      ${RED}exit 1-124${END}:   Mark this operation as bad/failed.
      ${RED}exit 128-255${END}:  Abort the process immediately.
EOF
    bash -i
    rv=$?
    return "${rv}"
}

function perform_custom_setup_script() {
    if [[ -z "$WITH_SETUP_SCRIPT" ]]; then
        return 0
    fi

    local main_repo_root=""
    for type_code in "${!ID_TYPES[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "fixed_commit" ]]; then
            main_repo_root="${TREE_PATHS[$type_code]}"
            break
        fi
    done

    if [[ -z "$main_repo_root" ]]; then
         log_warn "Could not determine main repo root for custom setup script. Skipping."
         return 0
    fi

    log_info "--- Running custom setup script: $WITH_SETUP_SCRIPT ---"

    while true; do
        (
            cd "$main_repo_root" || exit 1
            "$WITH_SETUP_SCRIPT"
        )
        local setup_status=$?
        if (( setup_status == 0 )); then
            log_info "Custom setup script succeeded."
            return 0
        fi

        log_warn "Custom setup script failed (exit code $setup_status)."

        enter_interactive_fix_mode "Custom setup script failed."
        local user_choice=$?

        if (( user_choice == 0 )); then
            log_info "User chose to retry setup script..."
            continue
        elif (( user_choice >= 128 )); then
            fail_error "Process aborted by user (exit code $user_choice)." "$user_choice"
        else
            return "$user_choice"
        fi
    done
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
    readonly GSI_BUILD
    readonly KERNEL_BUILD
    readonly VENDOR_KERNEL_BUILD
    readonly SERIAL_NUMBER
    readonly TEST_SUITE_BUILD
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

    # Run custom setup script
    local custom_setup_result
    perform_custom_setup_script
    custom_setup_result=$?
    if (( custom_setup_result != 0 )); then
        fail_error "Setup aborted/failed in custom script." "$custom_setup_result"
    fi

    # Prepare test suite
    if [[ -n "$TEST_SUITE_BUILD" && "$TEST_SUITE_BUILD" != "$CURRENT_TEST_SUITE_LOCATOR" ]]; then
        prepare_test_suite "$TEST_SUITE_BUILD"
        CURRENT_TEST_SUITE_LOCATOR="$TEST_SUITE_BUILD"
    fi

    local -a setup_cmd_array=()
    if [[ "$DEVICE_TYPE" == "PHYSICAL" ]]; then
        setup_cmd_array=("$FLASH_DEVICE_SCRIPT" "-s" "$SERIAL_NUMBER")
    else
        setup_cmd_array=("$LAUNCH_CVD_SCRIPT")
    fi

    # Add build args
    for type_code in "${BUILD_SETUP_ORDER[@]}"; do
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

    local setup_status=1
    while true; do
        for i in $(seq 1 "$SETUP_RETRY"); do
            if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
                unbuffer "${setup_cmd_array[@]}" | tee "$ACLOUD_OUTPUT_FILE"
                setup_status=${PIPESTATUS[0]}
            else
                "${setup_cmd_array[@]}"
                setup_status=$?
            fi

            if (( setup_status == 0 )); then
                log_info "Device setup successful."
                break 2 # Break out of both the retry loop and the interactive while loop
            fi

            log_warn "Device setup failed (Attempt $i/$SETUP_RETRY). Retrying..."
        done

        if [[ "$NON_INTERACTIVE" == "false" ]]; then
            enter_interactive_fix_mode "Device setup (build/flash) failed after $SETUP_RETRY attempts."
            local interactive_status=$?
            if (( interactive_status == 0 )); then
                log_info "User requested retry. Re-running setup..."
                continue
            elif (( interactive_status >= 128 )); then
                fail_error "Process aborted by user (exit code $interactive_status)." "$interactive_status"
            else
                fail_error "Device setup marked as failed by user." 2
            fi
        else
            fail_error "Device setup failed in non-interactive mode." 2
        fi
    done

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
    local -a test_cmd=("$RUN_TEST_SCRIPT" "-td" "$TEST_DIR")
    test_cmd+=("-s" "$adb_serial")

    if [[ -n "$OUTPUT_DIR" ]]; then
        local logs_dir="${OUTPUT_DIR}/test_logs"
        test_cmd+=("-tl" "$logs_dir")
    fi

    for test in "${TEST_NAME[@]}"; do
        test_cmd+=("-t" "$test")
    done

    log_info "Executing test command: ${test_cmd[*]}"
    for i in $(seq 1 "$TEST_RETRY"); do
        "${test_cmd[@]}"
        local test_status=$?
        if (( test_status == 0 )); then
            log_info "Tests PASSED."
            exit 0
        fi
        log_warn "Test failed (Attempt $i/$TEST_RETRY). Retrying..."
    done

    fail_error "Tests FAILED after $TEST_RETRY attempts." 1
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