#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

#
# A git-commit-level bisect testing tool to find breaking changes in an
# Android source tree, with support for bisecting multiple git projects
# simultaneously.
#

# --- Configuration Constants ---
readonly DEFAULT_BISECT_CONFIG_FILENAME="bisect_changes.xml"
readonly DEFAULT_OUTPUT_DIR="out/$(date +%Y%m%d_%H%M%S)"
readonly DEFAULT_TEST_RETRY=2
readonly DEFAULT_SETUP_RETRY=2
readonly DEFAULT_DOWNLOAD_RETRY=2
readonly -A BUILD_TYPE_MAP=(
    ["pb"]="PLATFORM_BUILD"
    ["kb"]="KERNEL_BUILD"
    ["vkb"]="VENDOR_KERNEL_BUILD"
    ["sb"]="GSI_BUILD"
    ["tb"]="TEST_SUITE_BUILD"
)
# Defines the order in which breaking projects are identified and bisected.
readonly -a BISECT_ORDER=("kb" "vkb" "pb" "sb" "tb")

# --- Global Variables ---
ACLOUD_OUTPUT_FILE="/tmp/ACLOUD_OUTPUT.tmp"
DEVICE_TYPE=""
PLATFORM_BUILD=""
KERNEL_BUILD=""
VENDOR_KERNEL_BUILD=""
GSI_BUILD=""
SERIAL_NUMBER=""
TEST_NAME=()
TEST_DIR=""
TEST_SUITE_BUILD=""
TEST_RETRY=$DEFAULT_TEST_RETRY
SETUP_RETRY=$DEFAULT_SETUP_RETRY
OUTPUT_DIR=""
INPUT_CONFIG_FILE=""
BISECT_CONFIG_FILE=""
SKIP_BUILD=false
NON_INTERACTIVE=false
WITH_SETUP_SCRIPT=""
TEMP_FILES=("$ACLOUD_OUTPUT_FILE")
TEMP_DIRS=()
# Tracks the source of the currently prepared test suite to avoid re-downloads.
CURRENT_TEST_SUITE_LOCATOR=""

# --- Multi-Bisection State Variables ---
# These associative arrays store the state for each build type being bisected.
# They are keyed by the build type code (e.g., 'pb', 'kb').
declare -A ID_TYPES
declare -A TREE_PATHS
declare -A PROJECTS
declare -A ORIGINAL_GIT_STATES # Stores original branch/commit before checkout
declare -A COMMITS_TO_TEST_MAP # Stores commit hashes as space-separated strings
declare -A COMMIT_STATUSES # Stores status ("good", "bad", "skipped") for each commit index
declare -A GOOD_INDICES
declare -A BAD_INDICES
declare -A IS_BREAKING

# Holds the list of build type codes that were identified as breaking.
BISECT_BUILD_TYPES=()
BISECT_STATUS=""

# --- Library Import ---
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
LIB_PATH="${SCRIPT_DIR}/common_lib.sh"
if [[ ! -f "$LIB_PATH" ]]; then
    echo "FATAL ERROR: Cannot find required library '$LIB_PATH'" >&2
    exit 1
fi
if ! . "$LIB_PATH"; then
    echo "FATAL ERROR: Failed to source library '$LIB_PATH'. Check common_lib.sh dependencies." >&2
    exit 1
fi

# Import xml_util
XML_UTIL_PATH="${SCRIPT_DIR}/lib/xml_util.sh"
if [[ ! -f "$XML_UTIL_PATH" ]]; then
    fail_error "FATAL ERROR: Cannot find required library 'xml_util.sh' in ${SCRIPT_DIR}/lib"
fi
if ! . "$XML_UTIL_PATH"; then
    fail_error "FATAL ERROR: Failed to source library '$XML_UTIL_PATH'"
fi

# Import device_util
DEVICE_UTIL_PATH="${SCRIPT_DIR}/lib/device_util.sh"
if [[ ! -f "$DEVICE_UTIL_PATH" ]]; then
    fail_error "FATAL ERROR: Cannot find required library 'device_util.sh' in ${SCRIPT_DIR}/lib"
fi
if ! . "$DEVICE_UTIL_PATH"; then
    fail_error "FATAL ERROR: Failed to source library '$DEVICE_UTIL_PATH'"
fi

# --- Scripts ---
readonly LAUNCH_CVD_SCRIPT="${SCRIPT_DIR}/launch_cvd.sh"
readonly FLASH_DEVICE_SCRIPT="${SCRIPT_DIR}/flash_device.sh"
readonly RUN_TEST_SCRIPT="${SCRIPT_DIR}/run_test_only.sh"
readonly FETCH_ARTIFACT_SCRIPT="${SCRIPT_DIR}/fetch_artifact.sh"

# --- Functions ---
function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "A tool to perform git commit-level bisection OR a single test run."
    echo "This version supports bisecting multiple git projects simultaneously."
    echo ""
    echo "To start a new bisection, specify one or more build arguments with a commit range or list."
    echo ""
    echo "Multi-Project Bisection Workflow:"
    echo "  When multiple commit ranges are provided, the script first determines which git"
    echo "  project(s) are responsible for the failure before starting the bisection."
    echo ""
    echo "Modes:"
    echo "  New Bisection: Provide build ranges via -pb, -kb, -vkb, -sb, or -tb, along with -t."
    echo "  Resume Bisection: Provide -i to resume a previously started bisection."
    echo ""
    echo "Build String Format:"
    echo "  For Bisection (range or list):"
    echo "    \$ANDROID_TREE_PATH/\$PROJECT_PATH:\$START_COMMIT-\$END_COMMIT"
    echo "    \$ANDROID_TREE_PATH/\$PROJECT_PATH:\$COMMIT1,\$COMMIT2,..."
    echo "  For Fixed Commit (not bisected):"
    echo "    \$ANDROID_TREE_PATH/\$PROJECT_PATH:\$SINGLE_COMMIT"
    echo "  For Fixed Remote Build:"
    echo "    ab://<branch>/<target>/<build_id>"
    echo "  For Fixed Local Tree:"
    echo "    /path/to/local/android/tree"
    echo "  For Skipping specific build (Physical Device Only):"
    echo "    none"
    echo ""
    echo "Options:"
    echo "  -pb,  --platform-build <string>"
    echo "                                   Platform build definition. Can be set to 'none' for physical devices to skip flashing."
    echo "  -kb,  --kernel-build, -gki, --gki-build <string>"
    echo "                                   Kernel build definition. Can be set to 'none' for physical devices to skip flashing."
    echo "  -vkb, --vendor-kernel-build <string>"
    echo "                                   Vendor kernel build definition. Can be set to 'none' for physical devices to skip flashing."
    echo "  -sb,  --system-build, -gsi, --gsi-build <string>"
    echo "                                   System (GSI) build definition. Can be set to 'none' for physical devices to skip flashing."
    echo "  -s,   --serial-number <serial>   The physical device serial. If omitted, uses a Cuttlefish virtual device."
    echo "  -t,   --test <name>              [Required] The test name(s) to run. Can be repeated."
    echo "  -td, --test-dir, -tb, --test-suite-build <string>"
    echo "                                   [Required] Test suite definition. Can be a bisection string, fixed URL, or local path."
    echo "  -tr,  --test-retry <count>       Retry count for a failed test. Default: ${DEFAULT_TEST_RETRY}."
    echo "  -sr,  --setup-retry <count>      Retry count for failed device setup. Default: ${DEFAULT_SETUP_RETRY}."
    echo "  --skip-build                     [Optional] Pass '--skip-build' to underlying flash/launch scripts."
    echo "  --non-interactive                [Optional] Disable interactive mode on build failures."
    echo "  --with-setup <script_path>       [Optional] Path to a custom script to run after checkout, before build."
    echo "  -od,  --output-dir <path>        Directory to store the state XML file. Default: ${DEFAULT_OUTPUT_DIR}/${DEFAULT_BISECT_CONFIG_FILENAME}."
    echo "  -i,   --input-config-file <path> Resume bisection from the given state XML file."
    echo "  -h,   --help                     Display this help message."
    echo ""
    echo "Examples:"
    echo "  # Bisection Mode: Bisect a commit range in a specific project"
    echo "  $0 -pb ~/main/vendor/xts:c1d2e3f-a7b8c9d -t MyTest -td /path/to/android-cts"
    echo ""
    echo "  # Bisect one project while pinning another to a specific commit"
    echo "  $0 -pb ~/main/frameworks/base:a1b2c3d-e4f5a6b -kb ~/main/kernel/common:abc1234 -t MyTest -td /path/to/android-cts"
    echo ""

    echo "  # Resume an interrupted bisection"
    echo "  $0 -i out/20250910_153000/bisect_changes.xml"
}

function fail_error() {
    local message="$1"
    local exit_code="${2:-1}"
    log_error "$message" "$exit_code" 2 # Report from the caller of fail_error
    exit "$exit_code"
}

function cleanup() {
    log_info "Cleaning up..."
    restore_all_git_states
    if (( ${#TEMP_FILES[@]} > 0 )); then
        rm -f "${TEMP_FILES[@]}"
    fi
    if (( ${#TEMP_DIRS[@]} > 0 )); then
        rm -rf "${TEMP_DIRS[@]}"
    fi
    log_info "Cleanup finished."
}

function parse_args() {
    local has_input_file=false
    local has_new_bisect_args=false

    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            -i|--input-config-file)
                shift
                INPUT_CONFIG_FILE="$1"
                has_input_file=true
                shift
                ;;
            -od|--output-dir)
                shift
                OUTPUT_DIR="$1"
                has_new_bisect_args=true
                shift
                ;;
            -pb|--platform-build)
                shift
                PLATFORM_BUILD="$1"
                has_new_bisect_args=true
                shift
                ;;
            -kb|--kernel-build|-gki|--gki-build)
                shift
                KERNEL_BUILD="$1"
                has_new_bisect_args=true
                shift
                ;;
            -vkb|--vendor-kernel-build)
                shift
                VENDOR_KERNEL_BUILD="$1"
                has_new_bisect_args=true
                shift
                ;;
            -sb|--system-build|-gsi|--gsi-build)
                shift
                GSI_BUILD="$1"
                has_new_bisect_args=true
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
                has_new_bisect_args=true
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
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --with-setup)
                shift
                WITH_SETUP_SCRIPT="$1"
                has_new_bisect_args=true
                shift
                ;;
            *)
                fail_error "Unsupported flag: $1"
                ;;
        esac
    done

    if "$has_input_file"; then
        if [[ ! -f "$INPUT_CONFIG_FILE" ]]; then
            fail_error "Input config file not found: $INPUT_CONFIG_FILE"
        fi
    fi

    if "$has_input_file" && "$has_new_bisect_args"; then
        fail_error "Cannot specify new bisection options (-pb, -kb, etc.) when resuming with -i."
    fi

    if ! "$has_input_file"; then
        if [[ -z "$TEST_SUITE_BUILD" ]] || (( ${#TEST_NAME[@]} == 0 )); then
             fail_error "For a new run, both --test (-t) and --test-dir|--test-suite-build (-td|-tb) must be specified."
        fi
        if [[ -n "$WITH_SETUP_SCRIPT" && ! -x "$WITH_SETUP_SCRIPT" ]]; then
            fail_error "The --with-setup script '$WITH_SETUP_SCRIPT' is not executable or does not exist."
        fi
    fi
}

function parse_change_string() {
    local build_str="$1"
    local -n tree_path_ref="$2"
    local -n project_ref="$3"
    local -n commits_ref="$4"
    local -n type_ref="$5" # 'range', 'list', 'local', 'ab', 'fixed_commit', 'none'

    # Support for "none" to skip flashing specific build artifacts
    if [[ "${build_str,,}" == "none" ]]; then
        type_ref="none"
        commits_ref=("none")
        tree_path_ref="none"
        project_ref="none"
        return 0
    fi

    # Check for ab:// URL first
    if [[ "$build_str" == ab://* ]]; then
        type_ref="ab"
        commits_ref=("$build_str")
        return 0
    fi

    # Check for local path without project/commit part
    if [[ ! "$build_str" == *:* ]]; then
        if [[ -d "$build_str" ]]; then
            type_ref="local"
            commits_ref=("$build_str")
            return 0
        else
            fail_error "Build string is not a valid directory: $build_str"
        fi
    fi

    # It's a format with a colon
    local path_part="${build_str%%:*}"
    local commit_part="${build_str#*:}"

    tree_path_ref="${path_part%/*}"
    # If tree_path is '.' , resolve it to the full path
    if [[ "$tree_path_ref" == "." ]]; then
        tree_path_ref=$PWD
    fi
    # Expand tilde
    tree_path_ref="${tree_path_ref/#\~/$HOME}"


    project_ref="${path_part##*/}"
    # Special handling for tb as it has a nested structure
    if [[ "$build_str" == *"/test/vts:"* ]]; then
        project_ref="test/vts"
        tree_path_ref="${path_part%/test/vts}"
    elif [[ "$build_str" == *"/cts:"* ]]; then
        project_ref="cts"
        tree_path_ref="${path_part%/cts}"
    fi

    if [[ "$commit_part" == *","* ]]; then
        type_ref="list"
        local old_ifs=$IFS; IFS=','
        read -r -a commits_ref <<< "$commit_part"
        IFS=$old_ifs
    elif [[ "$commit_part" == *"-"* ]]; then
        type_ref="range"
        local c1 c2
        c1=$(echo "$commit_part" | cut -d'-' -f1)
        c2=$(echo "$commit_part" | cut -d'-' -f2)
        commits_ref=("$c1" "$c2")
    elif [[ -n "$commit_part" ]]; then
        # It's a single commit, not a range or list
        type_ref="fixed_commit"
        commits_ref=("$commit_part")
    else
        fail_error "Invalid commit format. Commit part is empty for: $build_str"
    fi
    return 0
}

function get_commits_in_range() {
    local project_path="$1"
    local start_commit="$2"
    local end_commit="$3"
    local -n result_array_ref="$4"

    log_info "Fetching all commits in project '$project_path' from $start_commit to $end_commit..."

    # Use rev-list to get all commits between start (exclusive) and end (inclusive)
    mapfile -t result_array_ref < <(cd "$project_path" && git rev-list --ancestry-path --reverse "$start_commit..$end_commit")

    if (( ${#result_array_ref[@]} == 0 )); then
        fail_error "Could not find any commits between ${start_commit} and ${end_commit} for project ${project_path}."
    fi
    log_info "Found ${#result_array_ref[@]} commits to test for ${project_path}."
}

function validate_and_process_args() {
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
    fi
    OUTPUT_DIR=$(realpath "$OUTPUT_DIR")
    BISECT_CONFIG_FILE="${OUTPUT_DIR}/${DEFAULT_BISECT_CONFIG_FILENAME}"

    if [[ -n "$INPUT_CONFIG_FILE" ]]; then
        return 0
    fi

    # Determine device type for validation
    local current_device_type="VIRTUAL"
    if [[ -n "$SERIAL_NUMBER" ]]; then
        current_device_type="PHYSICAL"
    fi

    # --- New Run Validations ---
    local has_bisection_target=false
    local script_root_dir
    script_root_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

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

        if [[ "$id_type" == "none" ]]; then
            if [[ "$type_code" == "tb" ]]; then
                fail_error "Test suite ('tb') cannot be set to 'none'."
            fi
            if [[ "$current_device_type" != "PHYSICAL" ]]; then
                fail_error "Setting build to 'none' is only supported for Physical Devices (with -s)."
            fi
            continue # Skip git validation for 'none'
        fi

        if [[ "$id_type" == "range" || "$id_type" == "list" || "$id_type" == "fixed_commit" ]]; then
            # --- Shared validation for all git-based types ---
            log_info "Validating git argument for '$type_code' (type: $id_type)..."
            TREE_PATHS[$type_code]="$tree_path"
            PROJECTS[$type_code]="$project"

            # 1. Check Android Source Tree Path
            if [[ ! -d "$tree_path" ]]; then
                fail_error "[$type_code] Android source tree path does not exist: $tree_path"
            fi
            if [[ "$(realpath "$tree_path")" == "$(realpath "$script_root_dir")" ]]; then
                fail_error "[$type_code] Android source tree path cannot be the same as the script's root directory."
            fi

            local full_project_path="${tree_path}/${project}"
            if [[ ! -d "$full_project_path/.git" ]]; then
                fail_error "[$type_code] Project path is not a git repository: $full_project_path"
            fi

            # 2. Verify project exists in `repo list`
            local repo_list_output
            repo_list_output=$(cd "$tree_path" && repo list)
            if ! echo "$repo_list_output" | grep -q "^${project} "; then
                 fail_error "[$type_code] Project path '${project}' not found in 'repo list' for tree '${tree_path}'."
            fi

            # 3. Verify commits
            for commit in "${commits[@]}"; do
                if ! (cd "$full_project_path" && git cat-file -e "$commit" &>/dev/null); then
                    fail_error "[$type_code] Commit ID '$commit' does not exist in project '$project'."
                fi
            done

            # --- Type-specific validation ---
            if [[ "$id_type" == "range" || "$id_type" == "list" ]]; then
                has_bisection_target=true
                local -a commits_to_test=()
                if [[ "$id_type" == "range" ]]; then
                    local start_commit="${commits[0]}"
                    local end_commit="${commits[1]}"
                    # 4. Check commit order for range
                    if ! (cd "$full_project_path" && git merge-base --is-ancestor "$start_commit" "$end_commit"); then
                        fail_error "[$type_code] Start commit $start_commit is not an ancestor of end commit $end_commit."
                    fi
                    get_commits_in_range "$full_project_path" "$start_commit" "$end_commit" commits_to_test
                else # list
                    # 5. Check commit order for list
                    local sorted_commits
                    sorted_commits=($(cd "$full_project_path" && git rev-list --topo-order --no-walk "${commits[@]}"))
                    for i in "${!commits[@]}"; do
                        if [[ "${commits[$i]}" != "${sorted_commits[$i]}" ]]; then
                            fail_error "[$type_code] Commit list is not in ascending chronological order. Expected order starts with: ${sorted_commits[*]}"
                        fi
                    done
                    commits_to_test=("${commits[@]}")
                fi

                if (( ${#commits_to_test[@]} < 2 )); then
                     fail_error "Bisection for '$type_code' requires at least two commits. Found ${#commits_to_test[@]}."
                fi
                COMMITS_TO_TEST_MAP[$type_code]="${commits_to_test[*]}"
            else # fixed_commit
                COMMITS_TO_TEST_MAP[$type_code]="${commits[0]}" # Store the single commit
            fi

            save_initial_git_state "$type_code"
        fi
    done

    if ! "$has_bisection_target"; then
        fail_error "No bisection arguments (range/list) found. Bisection requires at least one commit range or list."
    fi

    # We only need to prepare it if it's a fixed 'ab' or 'local' type.
    # 'fixed_commit' and 'bisection' types are handled during the test run.
    if [[ "${ID_TYPES[tb]}" == "ab" || "${ID_TYPES[tb]}" == "local" ]]; then
        if [[ -n "$TEST_SUITE_BUILD" ]]; then
            prepare_test_suite "$TEST_SUITE_BUILD"
        fi
    fi
}

function save_initial_git_state() {
    local type_code="$1"
    local project_path="${TREE_PATHS[$type_code]}/${PROJECTS[$type_code]}"
    log_info "Saving initial git state for project: $project_path"

    # Check for detached HEAD state
    local head_state
    head_state=$(cd "$project_path" && git symbolic-ref --short -q HEAD || git rev-parse HEAD)
    ORIGINAL_GIT_STATES[$type_code]="$head_state"
    log_info "[$type_code] Original HEAD is: ${head_state}"
}

function restore_all_git_states() {
    log_info "Restoring all modified git repositories to their original state..."
    for type_code in "${!ORIGINAL_GIT_STATES[@]}"; do
        local original_state="${ORIGINAL_GIT_STATES[$type_code]}"
        if [[ -z "$original_state" ]]; then
            continue
        fi
        local project_path="${TREE_PATHS[$type_code]}/${PROJECTS[$type_code]}"
        if [[ -d "$project_path/.git" ]]; then
            log_info "Restoring project '$project_path' to '$original_state'..."
            (cd "$project_path" && git checkout "$original_state")
            if (( $? != 0 )); then
                log_error "Failed to restore project '$project_path' to '$original_state'."
            fi
        fi
    done
}

# --- XML Functions ---
function init_bisect_file() {
    log_info "Initializing new bisection state file: $BISECT_CONFIG_FILE"
    xml_util::init "$BISECT_CONFIG_FILE" "bisect" || fail_error "Failed to initialize XML file: $BISECT_CONFIG_FILE"

    local -a xml_edit_cmd=("xmlstarlet" "ed" "-L")
    xml_util::add_node       xml_edit_cmd "/bisect" "state"
    xml_util::add_attribute  xml_edit_cmd "/bisect/state" "status" "new"

    xml_util::add_node       xml_edit_cmd "/bisect" "parameters"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "test_dir"      "$TEST_DIR"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "output_dir"    "$OUTPUT_DIR"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "test_retry"    "$TEST_RETRY"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "setup_retry"   "$SETUP_RETRY"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "serial_number" "$SERIAL_NUMBER"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "skip_build"    "$SKIP_BUILD"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "non_interactive" "$NON_INTERACTIVE"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "with_setup_script" "$WITH_SETUP_SCRIPT"
    for test in "${TEST_NAME[@]}"; do
        xml_util::add_element xml_edit_cmd "/bisect/parameters" "test" "$test"
    done

    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local build_value="${!var_name}"
        if [[ -z "$build_value" ]]; then
            continue
        fi

        if [[ "${ID_TYPES[$type_code]}" == "list" || "${ID_TYPES[$type_code]}" == "range" ]]; then
            local node_name="${var_name,,}s" # e.g., platform_builds
            xml_util::add_node       xml_edit_cmd "/bisect" "$node_name"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$node_name" "id_type" "${ID_TYPES[$type_code]}"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$node_name" "path" "${TREE_PATHS[$type_code]}"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$node_name" "project" "${PROJECTS[$type_code]}"

            local -a commits_arr=(${COMMITS_TO_TEST_MAP[$type_code]})
            for commit in "${commits_arr[@]}"; do
                # Add change with default "unknown" status
                xml_util::add_element_with_attr xml_edit_cmd "/bisect/$node_name" "change" "$commit" "status" "unknown"
            done
        else
            # This handles "ab", "local", "fixed_commit", and "none" types
            local single_node_name="${var_name,,}" # e.g., platform_build
            xml_util::add_node       xml_edit_cmd "/bisect" "$single_node_name"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$single_node_name" "id_type" "${ID_TYPES[$type_code]}"
            xml_edit_cmd+=(-u "/bisect/$single_node_name" -v "$build_value")
        fi
    done
    "${xml_edit_cmd[@]}" "$BISECT_CONFIG_FILE" || fail_error "Failed to populate initial bisection XML data."
}

function load_state_from_xml() {
    log_info "Loading state from ${BISECT_CONFIG_FILE}..."
    BISECT_STATUS=$(xml_util::read_value "/bisect/state/@status")
    local has_bisection_node=false

    # Parameters
    TEST_DIR=$(xml_util::read_value "/bisect/parameters/@test_dir")
    OUTPUT_DIR=$(xml_util::read_value "/bisect/parameters/@output_dir")
    TEST_RETRY=$(xml_util::read_value "/bisect/parameters/@test_retry")
    SETUP_RETRY=$(xml_util::read_value "/bisect/parameters/@setup_retry")
    SERIAL_NUMBER=$(xml_util::read_value "/bisect/parameters/@serial_number")
    SKIP_BUILD=$(xml_util::read_value "/bisect/parameters/@skip_build")
    NON_INTERACTIVE=$(xml_util::read_value "/bisect/parameters/@non_interactive")
    WITH_SETUP_SCRIPT=$(xml_util::read_value "/bisect/parameters/@with_setup_script")
    xml_util::read_values_to_array "/bisect/parameters/test" TEST_NAME

    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local plural_node_name="${var_name,,}s"
        local single_node_name="${var_name,,}"

        local id_type=$(xml_util::read_value "/bisect/$plural_node_name/@id_type")
        if [[ "$id_type" == "range" || "$id_type" == "list" ]]; then
            has_bisection_node=true
            ID_TYPES[$type_code]="$id_type"
            TREE_PATHS[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@path")
            PROJECTS[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@project")
            GOOD_INDICES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@good_index")
            BAD_INDICES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@bad_index")
            IS_BREAKING[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@is_breaking")

            local -a commits_arr=()
            local -a statuses_arr=()
            xml_util::read_values_to_array "/bisect/$plural_node_name/change" commits_arr
            xml_util::read_attributes_to_array "/bisect/$plural_node_name/change/@status" statuses_arr
            COMMITS_TO_TEST_MAP[$type_code]="${commits_arr[*]}"

            # Load commit statuses
            for i in "${!commits_arr[@]}"; do
                local commit="${commits_arr[$i]}"
                local status="${statuses_arr[$i]}"
                COMMIT_STATUSES["$type_code:$i"]="$status"
            done

            if [[ "${IS_BREAKING[$type_code]}" == "true" ]]; then
                BISECT_BUILD_TYPES+=("$type_code")
            fi
            # Must save the initial state for cleanup on resume
            save_initial_git_state "$type_code"
        else
            id_type=$(xml_util::read_value "/bisect/$single_node_name/@id_type")
            if [[ -n "$id_type" ]]; then
                ID_TYPES[$type_code]="$id_type"
                local build_val
                build_val=$(xml_util::read_value "/bisect/$single_node_name")
                printf -v "$var_name" "%s" "$build_val" # e.g., PLATFORM_BUILD="~/main/fw/base:abc1234"

                if [[ "$id_type" == "fixed_commit" ]]; then
                    # Re-parse the string to populate our maps for checkout/cleanup
                    local tree_path project
                    local -a commits=()
                    local parsed_type=""
                    parse_change_string "$build_val" tree_path project commits parsed_type
                    TREE_PATHS[$type_code]="$tree_path"
                    PROJECTS[$type_code]="$project"
                    COMMITS_TO_TEST_MAP[$type_code]="${commits[0]}" # Store the single commit
                    # We must save the initial state for cleanup on resume
                    save_initial_git_state "$type_code"
                fi
            fi
        fi
    done

    # Prepare the test suite if it's a fixed path from the XML
    # Note: TEST_SUITE_BUILD is the global variable holding the raw string
    if [[ -n "$TEST_SUITE_BUILD" ]]; then
        prepare_test_suite "$TEST_SUITE_BUILD"
    fi

    if ! "$has_bisection_node"; then
        fail_error "Loaded XML state does not contain any bisection nodes."
    fi

    log_info "State loaded successfully. Status: $BISECT_STATUS."
}

function xml_util::update_change_status_by_index() {
    local type_code="$1"
    local commit_index="$2" # This is the 0-based index
    local status="$3"

    local var_name="${BUILD_TYPE_MAP[$type_code]}"
    local node_name="${var_name,,}s"
    # XML is 1-based, so add 1
    local change_xpath="/bisect/$node_name/change[$((commit_index + 1))]"

    xml_util::update_xml_attribute "${change_xpath}" "status" "$status"
}

# --- Test Suite Caching ---
function parse_build_string() {
    local build_str="$1"
    local -n branch_ref="$2"
    local -n target_ref="$3"
    local -n ids_ref="$4"
    local -n type_ref="$5" # Will be 'range', 'list', 'single', 'local', or 'none'
    local -n filename_ref="$6"

    # Support for "none" to skip flashing specific build artifacts
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
        type_ref="list"
        local old_ifs=$IFS; IFS=','
        read -r -a ids_ref <<< "$id_part"
        IFS=$old_ifs
        for id in "${ids_ref[@]}"; do
            if ! [[ "$id" =~ ^[0-9]+$ ]]; then
                fail_error "Invalid build ID in list. All IDs must be numeric: $id"
            fi
        done
        mapfile -t sorted_ids < <(printf "%s\n" "${ids_ref[@]}" | sort -n)
        ids_ref=("${sorted_ids[@]}")
    elif [[ "$id_part" == *"-"* ]]; then
        type_ref="range"
        local id1 id2
        id1=$(echo "$id_part" | cut -d'-' -f1)
        id2=$(echo "$id_part" | cut -d'-' -f2)
        if ! [[ "$id1" =~ ^[0-9]+$ && "$id2" =~ ^[0-9]+$ ]]; then
            fail_error "Invalid range format. IDs must be numeric: $id_part"
        fi
        if (( id1 >= id2 )); then
            fail_error "Invalid range: start ID ($id1) must be less than end ID ($id2)."
        fi
        ids_ref=("$id1" "$id2")
    else
        type_ref="single"
        # A single ID can be numeric or "latest"
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

    # If it's a local path, just update the state and return.
    if [[ "$required_locator" != ab://* ]]; then
        TEST_DIR="$required_locator"
        return $EXIT_SUCCESS
    fi

    # For ab:// URLs, check the cache.
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
        # Update the required_locator so handle_test_suite_url uses the numeric ID
        required_locator="ab://${branch}/${target}/${resolved_id}/${filename}"
    fi

    local base_dir
    base_dir=$(get_test_suite_base_dir)

    local suite_base_path="${base_dir}/${branch}/${target}/${build_id[0]}"
    if [[ -d "$suite_base_path" ]]; then
        # The base directory exists, check for a single unzipped subdirectory.
        local unzipped_dir
        unzipped_dir=$(find "$suite_base_path" -mindepth 1 -maxdepth 1 -type d)
        if [[ -n "$unzipped_dir" && -d "$unzipped_dir" ]]; then
            log_info "Found existing test suite in cache: $unzipped_dir"
            TEST_DIR="$unzipped_dir"
            return $EXIT_SUCCESS
        fi
    fi

    # If not cached, download it.
    log_info "Test suite not found in cache. Downloading..."
    handle_test_suite_url "$required_locator"
}

# --- Core Bisection and Testing Logic ---

function checkout_commit() {
    local type_code="$1"
    local commit_hash="$2"
    local project_path="${TREE_PATHS[$type_code]}/${PROJECTS[$type_code]}"
    log_info "Checking out commit '$commit_hash' in project '$project_path'..."
    (cd "$project_path" && git checkout "$commit_hash")
    if (( $? != 0 )); then
        log_error "Failed to checkout commit '$commit_hash' in '$project_path'."
        return 1
    fi
    return 0
}

function enter_interactive_fix_mode() {
    local prompt_message="$1"
    if "$NON_INTERACTIVE"; then
        log_error "${prompt_message} Failed in non-interactive mode."
        # Return 5, which maps to "bad"
        return 5
    fi

    local rv=5 # Default to 'bad'
    cat <<-EOF 1>&2
    ${YELLOW}${prompt_message}${END}
    Spawning a new shell.
    You can attempt to fix the issue (e.g., resolve merge conflicts).
    Once done, exit this shell with one of the following codes:
      ${GREEN}exit 0${END}:     Retry the operation. If successful, bisection continues.
      ${ORANGE}exit 125${END}:   '${BOLD}Skip${END}${YELLOW}' this commit (mark as untestable).
      ${RED}exit 1-124${END}:   Mark this commit as '${BOLD}bad${END}${YELLOW}' (e.g., exit 1 or exit 5).
      ${RED}exit 128-255${END}:  '${BOLD}Abort${END}${YELLOW}' the entire bisection process immediately.
EOF
    bash -i
    rv=$?
    return "${rv}"
}

function find_real_middle_index() {
    local low_bound=$1
    local high_bound=$2
    local skipped_string=$3

    if ! [[ "$low_bound" =~ ^[0-9]+$ ]] || ! [[ "$high_bound" =~ ^[0-9]+$ ]]; then
        echo "Error: low_bound and high_bound should be numbers" >&2
        return 1
    fi

    local -A skipped_set
    for skip_val in $skipped_string; do
        skipped_set["$skip_val"]=1
    done

    local -a candidates=()

    # Find candidates between (low_bound, high_bound)
    for (( i=low_bound + 1; i<high_bound; i++ )); do
        if [[ -v skipped_set[$i] ]]; then
            continue
        else
            candidates+=($i)
        fi
    done

    local num_candidates=${#candidates[@]}
    if (( num_candidates == 0 )); then
        log_warn "In range ($low_bound, $high_bound), we can't find the index to be tested (all skipped)."
        return 1 # fail
    fi

    local middle_list_index=$(( (num_candidates - 1) / 2 ))

    echo "${candidates[$middle_list_index]}"
    return 0 # success
}

function perform_custom_setup_script() {
    if [[ -z "$WITH_SETUP_SCRIPT" ]]; then
        return 0 # No script provided, success.
    fi

    # Find the repo root for the *main* Android tree being tested.
    # We'll assume the first bisection target's tree is the main one.
    local main_repo_root=""
    for type_code in "${!ID_TYPES[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "range" || "${ID_TYPES[$type_code]}" == "list" ]]; then
            main_repo_root="${TREE_PATHS[$type_code]}"
            break
        fi
    done

    # If no bisection target, use the first fixed_commit target's tree
    if [[ -z "$main_repo_root" ]]; then
        for type_code in "${!ID_TYPES[@]}"; do
            if [[ "${ID_TYPES[$type_code]}" == "fixed_commit" ]]; then
                main_repo_root="${TREE_PATHS[$type_code]}"
                break
            fi
        done
    fi

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

        if (( user_choice == 0 )); then # Retry
            log_info "User chose to retry setup script..."
            continue # Continue the while loop
        elif (( user_choice >= 128 )); then # Abort
            fail_error "Bisection aborted by user (exit code $user_choice)." "$user_choice"
        else # Good (0), Skip (125), or Bad (1-124)
            # We return the code to the caller
            return "$user_choice"
        fi
    done
}

function setup_and_test_combination() {
    local -A builds_to_use
    for arg in "$@"; do
        local type_code="${arg%%:*}"
        local value="${arg#*:}" # Can be commit hash or ab:// URL or local path
        builds_to_use[$type_code]="$value"
    done

    # 1. Checkout all necessary commits (bisection targets + fixed_commit)
    log_info "--- Test Combination ---"
    # 1.1 Checkout bisection targets
    for type_code in "${!builds_to_use[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "range" || "${ID_TYPES[$type_code]}" == "list" ]]; then
            log_info "  - ${type_code} [BISECT] (${PROJECTS[$type_code]}): ${builds_to_use[$type_code]}"
            checkout_commit "$type_code" "${builds_to_use[$type_code]}" || return 1 # Propagate failure
        fi
    done
    # 1.2 Checkout fixed_commit dependencies
    log_info "--- Checking out fixed_commit dependencies ---"
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "fixed_commit" ]]; then
            local commit_hash="${COMMITS_TO_TEST_MAP[$type_code]}"
            log_info "  - ${type_code} [FIXED] (${PROJECTS[$type_code]}): $commit_hash"
            checkout_commit "$type_code" "$commit_hash" || return 1
        fi
    done
    log_info "--------------------------------------------"


    # 2. Run custom setup script (if provided)
    local custom_setup_result
    perform_custom_setup_script
    custom_setup_result=$?
    if (( custom_setup_result != 0 )); then
        if (( custom_setup_result >= 128 )); then
            fail_error "Bisection aborted by user (exit code $custom_setup_result)." "$custom_setup_result"
        fi
        return "$custom_setup_result"
    fi

    # 3. Prepare test suite (if it's not already)
    # This is critical for Single Run Mode, as it's not prepared in validate_and_process_args
    if [[ "$TEST_SUITE_BUILD" != "$CURRENT_TEST_SUITE_LOCATOR" ]]; then
        prepare_test_suite "$TEST_SUITE_BUILD"
    fi

    # 4. Construct and run setup command
    local -a setup_cmd_array=()
    if [[ "$DEVICE_TYPE" == "PHYSICAL" ]]; then
        setup_cmd_array=("$FLASH_DEVICE_SCRIPT" "-s" "$SERIAL_NUMBER")
    else
        # Connect Cuttlefish with adb connection only. Skip webrtc autoconnect
        setup_cmd_array=("$LAUNCH_CVD_SCRIPT" "--acloud-arg=--autoconnect" "--acloud-arg=adb")
    fi

    # Loop over all build types to construct command
    for type_code in pb kb vkb sb; do
        local id_type="${ID_TYPES[$type_code]}"
        if [[ -z "$id_type" ]]; then
            continue
        fi

        local arg_val=""
        if [[ "$id_type" == "none" ]]; then
            arg_val="none"
        elif [[ "$id_type" == "range" || "$id_type" == "list" || "$id_type" == "fixed_commit" ]]; then
            # For all git-based types, we pass the path to the Android tree
            arg_val="${TREE_PATHS[$type_code]}"
        else
            # For "ab" or "local" types
            local var_name="${BUILD_TYPE_MAP[$type_code]}"
            arg_val="${!var_name}"
        fi

        if [[ -n "$arg_val" ]]; then
            setup_cmd_array+=("-$type_code" "$arg_val")
        fi
    done

    # Handle -tb separately as it's not a build arg for setup scripts
    if [[ "${ID_TYPES[tb]}" == "range" || "${ID_TYPES[tb]}" == "list" || "${ID_TYPES[tb]}" == "fixed_commit" ]]; then
        TEST_DIR="${TREE_PATHS[tb]}"
    fi

    if "$SKIP_BUILD"; then
        setup_cmd_array+=("--skip-build")
    fi

    log_info "Executing device setup: ${setup_cmd_array[*]}"

    local setup_status=1
    while true; do # Infinite loop for retries
        if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
            unbuffer "${setup_cmd_array[@]}" | tee "$ACLOUD_OUTPUT_FILE"
            setup_status=${PIPESTATUS[0]}
        else
            "${setup_cmd_array[@]}"
            setup_status=$?
        fi

        if (( setup_status == 0 )); then
            log_info "Device setup successful."
            break # Success, exit while loop
        fi

        log_warn "Device setup failed (exit code $setup_status)."

        if [[ "$NON_INTERACTIVE" == "false" ]]; then
            enter_interactive_fix_mode "Device setup (build/flash) failed."
            local interactive_status=$?
            if (( interactive_status == 0 )); then # Retry
                log_info "User requested retry. Re-running setup..."
                continue
            elif (( interactive_status >= 128 )); then # Abort
                fail_error "Bisection aborted by user (exit code $interactive_status)." "$interactive_status"
            else # Skip (125) or Bad (1-124)
                return "$interactive_status"
            fi
        else
            # Non-interactive, setup failed, treat as 'bad'
            log_error "Device setup failed in non-interactive mode."
            return 5 # 5 maps to "bad"
        fi
    done

    # 5. Run tests
    run_tests_on_device
    return $?
}

function run_tests_on_device() {
    local input_serial_to_use="$SERIAL_NUMBER"

    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        if [[ -f "$ACLOUD_OUTPUT_FILE" ]]; then
            input_serial_to_use=$(grep -oP "ANDROID_SERIAL=\K[\.0-9:]+" "$ACLOUD_OUTPUT_FILE")
        fi
        if [[ -z "$input_serial_to_use" ]]; then
             log_error "Could not determine virtual device serial from output file."
             return 1
        fi
    fi

    if ! device_util::init "$input_serial_to_use"; then
        return 1
    fi

    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        device_util::wait_for_boot_complete || return 1
    else
        # Physical devices
        device_util::unlock_screen || return 1
        device_util::skip_setup_wizard || return 1
    fi

    local adb_serial
    adb_serial=$(device_util::get_adb_serial)

    local -a test_cmd=("$RUN_TEST_SCRIPT" "-td" "$TEST_DIR" "-tl" "$OUTPUT_DIR/test_logs")
    test_cmd+=("-s" "$adb_serial")

    for test in "${TEST_NAME[@]}"; do
        test_cmd+=("-t" "$test")
    done

    log_info "Executing test command: ${test_cmd[*]}"
    for i in $(seq 1 "$TEST_RETRY"); do
        "${test_cmd[@]}"
        if (( $? == 0 )); then
            log_info "Test SUCCEEDED."
            return 0 # GOOD
        fi
        log_warn "Test failed (Attempt $i/$TEST_RETRY). Retrying..."
    done

    log_warn "Test FAILED after $TEST_RETRY attempts."
    return 1 # BAD (test fail)
}


function validate_and_identify_breakage() {
    log_info "--- Step 1: Validating the initial 'all good' commit combination ---"
    local -a ranged_build_types=()
    local -a combination=()

    for type_code in "${!ID_TYPES[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "range" || "${ID_TYPES[$type_code]}" == "list" ]]; then
            ranged_build_types+=("$type_code")
            local -a commits=(${COMMITS_TO_TEST_MAP[$type_code]})
            combination+=("${type_code}:${commits[0]}")
        else
            # Add fixed dependencies (ab, local, fixed_commit) to the combination
            local var_name="${BUILD_TYPE_MAP[$type_code]}"
            if [[ -n "${!var_name}" ]]; then
                combination+=("${type_code}:${!var_name}")
            fi
        fi
    done

    log_info "Testing with initial good combination: ${combination[*]}"
    setup_and_test_combination "${combination[@]}"
    if (( $? != 0 )); then
        fail_error "Validation failed: The combination of the FIRST commits is FAILING the test."
    fi
    log_info "Initial 'all good' combination PASSED."

    # Mark first commit as 'good' in XML
    for type_code in "${ranged_build_types[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local node_name="${var_name,,}s"
        xml_util::update_xml_attribute "/bisect/$node_name/change[1]" "status" "good"
    done


    log_info "--- Step 2: Iteratively identifying breaking projects ---"
    for type_to_check in "${BISECT_ORDER[@]}"; do
        if [[ ! " ${ranged_build_types[*]} " =~ " ${type_to_check} " ]]; then
            continue
        fi

        local -a test_combination=()
        local -a commits_for_type=(${COMMITS_TO_TEST_MAP[$type_to_check]})
        local last_commit_index=$(( ${#commits_for_type[@]} - 1 ))
        test_combination+=("${type_to_check}:${commits_for_type[$last_commit_index]}")

        for other_type in "${ranged_build_types[@]}"; do
            if [[ "$other_type" != "$type_to_check" ]]; then
                local -a other_commits=(${COMMITS_TO_TEST_MAP[$other_type]})
                test_combination+=("${other_type}:${other_commits[0]}")
            fi
        done
        for type_code in "${!BUILD_TYPE_MAP[@]}"; do
             if [[ "${ID_TYPES[$type_code]}" != "range" && "${ID_TYPES[$type_code]}" != "list" ]]; then
                local var_name="${BUILD_TYPE_MAP[$type_code]}"
                if [[ -n "${!var_name}" ]]; then
                    test_combination+=("${type_code}:${!var_name}")
                fi
             fi
        done

        log_info "Checking for breakage in '${type_to_check}' using combination: ${test_combination[*]}"
        setup_and_test_combination "${test_combination[@]}"
        local test_status=$?

        local var_name="${BUILD_TYPE_MAP[$type_to_check]}"
        local node_name="${var_name,,}s"
        if (( test_status != 0 )); then
            log_info "RESULT: Found breaking project: ${type_to_check}"
            BISECT_BUILD_TYPES+=("$type_code_to_check")
            GOOD_INDICES[$type_to_check]=0
            BAD_INDICES[$type_to_check]=$last_commit_index
            IS_BREAKING[$type_to_check]=true

            xml_util::update_xml_attribute "/bisect/$node_name" "good_index" "0"
            xml_util::update_xml_attribute "/bisect/$node_name" "bad_index" "$last_commit_index"
            xml_util::update_xml_attribute "/bisect/$node_name" "is_breaking" "true"
            # Mark last commit as 'bad' in XML
            xml_util::update_xml_attribute "/bisect/$node_name/change[last()]" "status" "bad"
        else
            log_info "RESULT: Project '${type_to_check}' is NOT identified as breaking."
            IS_BREAKING[$type_to_check]=false
            xml_util::update_xml_attribute "/bisect/$node_name" "is_breaking" "false"
            # Mark last commit as 'good' in XML
            xml_util::update_xml_attribute "/bisect/$node_name/change[last()]" "status" "good"
        fi
    done

    if (( ${#BISECT_BUILD_TYPES[@]} == 0 )); then
        fail_error "Validation failed: No breaking projects were identified. The combination of all LAST commits seems to be passing."
    fi
    log_info "Validation complete. Breaking projects to be bisected: ${BISECT_BUILD_TYPES[*]}"
}

function bisect_single_project() {
    local type_code_to_bisect="$1"
    log_info "========================================="
    log_info "Starting Bisection Loop for: $type_code_to_bisect"
    log_info "========================================="

    local good_idx=${GOOD_INDICES[$type_code_to_bisect]}
    local bad_idx=${BAD_INDICES[$type_code_to_bisect]}
    local -a commits_to_test=(${COMMITS_TO_TEST_MAP[$type_code_to_bisect]})

    local var_name="${BUILD_TYPE_MAP[$type_code_to_bisect]}"
    local node_name="${var_name,,}s"

    # Build the initial string of skipped indices from the XML
    local skipped_indices_string=""
    for i in $(seq 0 $(( ${#commits_to_test[@]} - 1 )) ); do
        if [[ "${COMMIT_STATUSES["$type_code_to_bisect:$i"]}" == "skipped" ]]; then
            skipped_indices_string+=" $i"
        fi
    done
    if [[ -n "$skipped_indices_string" ]]; then
        log_info "Loaded skipped indices for $type_code_to_bisect: $skipped_indices_string"
    fi

    while (( good_idx + 1 < bad_idx )); do
        local mid_idx
        mid_idx=$(find_real_middle_index "$good_idx" "$bad_idx" "$skipped_indices_string")
        local find_idx_status=$?

        if (( find_idx_status != 0 )); then
            log_warn "Bisection stuck. No testable commits found between $good_idx and $bad_idx."
            break
        fi

        local mid_commit=${commits_to_test[$mid_idx]}
        log_info "--- Testing $type_code_to_bisect at index: $mid_idx (Commit: ${mid_commit:0:12}) ---"

        local -a test_combination=()
        test_combination+=("${type_code_to_bisect}:${mid_commit}")

        # Add "good" commit for other bisection targets
        for other_type in "${!BUILD_TYPE_MAP[@]}"; do
            if [[ "$other_type" == "$type_code_to_bisect" || -z "${ID_TYPES[$other_type]}" ]]; then
                continue
            fi
            if [[ "${ID_TYPES[$other_type]}" == "range" || "${ID_TYPES[$other_type]}" == "list" ]]; then
                local -a other_commits=(${COMMITS_TO_TEST_MAP[$other_type]})
                test_combination+=("${other_type}:${other_commits[0]}")
            fi
        done

        # Add fixed dependencies (ab, local, fixed_commit)
        for type_code in "${!BUILD_TYPE_MAP[@]}"; do
             if [[ "${ID_TYPES[$type_code]}" != "range" && "${ID_TYPES[$type_code]}" != "list" ]]; then
                local var_name="${BUILD_TYPE_MAP[$type_code]}"
                if [[ -n "${!var_name}" ]]; then
                    test_combination+=("${type_code}:${!var_name}")
                fi
             fi
        done

        log_info "Testing with combination: ${test_combination[*]}"
        setup_and_test_combination "${test_combination[@]}"
        local test_status=$?

        if (( test_status == 0 )); then # GOOD
            log_info "RESULT: Commit ${mid_commit:0:12} ($type_code_to_bisect) is GOOD."
            good_idx=$mid_idx
            GOOD_INDICES[$type_code_to_bisect]=$good_idx
            xml_util::update_xml_attribute "/bisect/$node_name" "good_index" "$good_idx"
            xml_util::update_change_status_by_index "$type_code_to_bisect" "$mid_idx" "good"
            COMMIT_STATUSES["$type_code_to_bisect:$mid_idx"]="good"
        elif (( test_status == 125 )); then # SKIP
            log_warn "RESULT: Commit ${mid_commit:0:12} ($type_code_to_bisect) is SKIPPED."
            # Add to our in-memory list of skipped indices
            skipped_indices_string+=" $mid_idx"
            COMMIT_STATUSES["$type_code_to_bisect:$mid_idx"]="skipped"
            xml_util::update_change_status_by_index "$type_code_to_bisect" "$mid_idx" "skipped"
            # DO NOT update good_idx or bad_idx, let the loop try again
        elif (( test_status > 0 && test_status < 128 )); then # BAD (1-124, including 1 for test fail)
            log_info "RESULT: Commit ${mid_commit:0:12} ($type_code_to_bisect) is BAD/BROKEN."
            bad_idx=$mid_idx
            BAD_INDICES[$type_code_to_bisect]=$bad_idx
            xml_util::update_xml_attribute "/bisect/$node_name" "bad_index" "$bad_idx"
            if (( test_status == 1 )); then
                 xml_util::update_change_status_by_index "$type_code_to_bisect" "$mid_idx" "bad" # Test failed
                 COMMIT_STATUSES["$type_code_to_bisect:$mid_idx"]="bad"
            else
                 xml_util::update_change_status_by_index "$type_code_to_bisect" "$mid_idx" "broken" # User marked bad/broken
                 COMMIT_STATUSES["$type_code_to_bisect:$mid_idx"]="broken"
            fi
        else # ABORT (128+)
            log_error "Bisection aborted by user (exit code $test_status)!"
            xml_util::update_change_status_by_index "$type_code_to_bisect" "$mid_idx" "abort"
            xml_util::update_xml_node "/bisect/state/@status" "aborted"
            exit "$test_status"
        fi
        log_info "New Range for $type_code_to_bisect: Index $good_idx (Good) to $bad_idx (Bad)"
    done
}

function bisect_all_breaking_projects() {
    for type_code in "${BISECT_ORDER[@]}"; do
        if [[ " ${BISECT_BUILD_TYPES[*]} " =~ " ${type_code} " ]]; then
            bisect_single_project "$type_code"
        fi
    done

    log_info "========================================="
    log_info "All Bisections Complete!"
    log_info "========================================="
    xml_util::update_xml_node "/bisect/state/@status" "complete"

    for type_code in "${BISECT_BUILD_TYPES[@]}"; do
        local good_idx=${GOOD_INDICES[$type_code]}
        local bad_idx=${BAD_INDICES[$type_code]}
        local -a commits=(${COMMITS_TO_TEST_MAP[$type_code]})
        local project_path="${PROJECTS[$type_code]}"

        local last_good_commit=${commits[$good_idx]}
        local first_bad_commit=${commits[$bad_idx]}

        echo ""
        log_info "--- Results for Project: ${project_path} ($type_code) ---"
        log_info "Last known good commit: $last_good_commit"
        log_info "${RED}First known bad commit: $first_bad_commit${END}"
        log_info "Git log: (cd ${TREE_PATHS[$type_code]}/${project_path} && git log ${last_good_commit}..${first_bad_commit})"
    done
}

# --- Main Script Logic ---
function main() {
    trap cleanup EXIT
    trap 'exit 130' INT   # Standard exit code for SIGINT (128+2)
    trap 'exit 143' TERM  # Standard exit code for SIGTERM (128+15)

    check_commands_available "xmlstarlet" "unzip" "git" "repo" || fail_error "One or more required commands are missing."

    parse_args "$@"

    if [[ -n "$INPUT_CONFIG_FILE" ]]; then
        log_info "Resuming run from $INPUT_CONFIG_FILE"
        BISECT_CONFIG_FILE="$INPUT_CONFIG_FILE"
        xml_util::load "$BISECT_CONFIG_FILE" || fail_error "Failed to load XML file: $BISECT_CONFIG_FILE"
    else
        validate_and_process_args
        log_info "Starting new bisection run..."
        init_bisect_file
    fi

    load_state_from_xml

    if [[ -z "$SERIAL_NUMBER" ]]; then
        DEVICE_TYPE="VIRTUAL"
    else
        DEVICE_TYPE="PHYSICAL"
    fi
    log_info "Device Type set to: $DEVICE_TYPE"

    # --- Bisection Mode ---
    log_info "Executing in Bisection mode."
    if [[ "$BISECT_STATUS" == "new" ]]; then
        log_info "--- New bisection: Validating boundaries to find breaking projects ---"
        validate_and_identify_breakage
        xml_util::update_xml_node "/bisect/state/@status" "in_progress"
    elif [[ "$BISECT_STATUS" == "complete" ]]; then
        log_info "Bisection is already complete according to state file. Rerunning final report."
        bisect_all_breaking_projects # Re-run report
        exit 0
    else
         log_info "--- Resuming bisection. Skipping boundary validation. ---"
    fi

    bisect_all_breaking_projects
}

# Execute main
main "$@"