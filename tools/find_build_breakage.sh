#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

#
# A build-level bisect testing tool to find breaking changes in Android builds,
# with support for bisecting multiple build types simultaneously.
#

# --- Configuration Constants ---
readonly DEFAULT_BISECT_CONFIG_FILENAME="bisect_builds.xml"
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
# Defines the order in which breaking builds are identified and bisected.
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
DRY_RUN=false
TEMP_FILES=("$ACLOUD_OUTPUT_FILE")
TEMP_DIRS=()
CURRENT_TEST_SUITE_LOCATOR=""
HAS_FLASHED_PB=false
# --- Multi-Bisection State Variables ---
# These associative arrays store the state for each build type being bisected.
# They are keyed by the build type code (e.g., 'pb', 'kb').
declare -A ID_TYPES
declare -A BRANCHES
declare -A TARGETS
declare -A FILENAMES
declare -A BUILDS_TO_TEST_MAP # Stores build ID arrays as space-separated strings
declare -A GOOD_INDICES
declare -A BAD_INDICES
declare -A IS_BREAKING

# Holds the list of build type codes that were identified as breaking.
BISECT_BUILD_TYPES=()
BISECT_STATUS=""
# Holds the project commit ranges for the breaking builds.
declare -A PROJECT_COMMIT_RANGES
PROJECTS_WITH_CHANGES=()

# --- Library Import ---
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
LIB_PATH="${SCRIPT_DIR}/common_lib.sh"
# Import common_lib
if [[ ! -f "$LIB_PATH" ]]; then
    echo "FATAL ERROR: Cannot find required library '$LIB_PATH'" >&2
    exit 1 # common_lib is not loaded yet
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
readonly QUERY_BUILD_SCRIPT="${SCRIPT_DIR}/query_build.sh"
readonly QUERY_CHANGE_SCRIPT="${SCRIPT_DIR}/query_change.sh"
readonly FETCH_ARTIFACT_SCRIPT="${SCRIPT_DIR}/fetch_artifact.sh"
readonly FIND_CHANGE_BREAKAGE_SCRIPT="${SCRIPT_DIR}/find_change_breakage.sh"
readonly SETUP_AND_TEST_SCRIPT="${SCRIPT_DIR}/setup_and_test.sh"

# --- Functions ---
function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "A tool to perform build-level bisection to find the first failing Android build."
    echo "This version supports bisecting multiple build types (e.g., platform and kernel) at the same time."
    echo ""
    echo "To start a new bisection, specify one or more build arguments with a range or list."
    echo ""
    echo "Multi-Build Bisection Workflow:"
    echo "  When multiple build ranges are provided, the script first determines which build"
    echo "  type(s) are responsible for the failure before starting the bisection."
    echo ""
    echo "  1. Initial Validation: The script confirms that the test passes using the EARLIEST"
    echo "     build ID from every provided range. This establishes a 'known good' baseline."
    echo ""
    echo "  2. Breaking Build Identification: To isolate the problem, the script systematically"
    echo "     tests the LATEST build of each type while keeping all other builds at their"
    echo "     earliest 'known good' version. If a test fails, that build type is marked"
    echo "     as a 'breaking' candidate because its range introduced the failure."
    echo ""
    echo "  3. Bisection Execution: The script then performs a standard bisection test only on"
    echo "     the build types identified as 'breaking'. For all other 'non-breaking' types,"
    echo "     it uses their initial, known-good build as a stable baseline throughout the process."
    echo ""
    echo "Modes:"
    echo "  New Bisection: Provide build ranges via -pb, -kb (or -gki), -vkb, -sb (or -gsi), or -td."
    echo "                 Use -t to specify a test. If -t is omitted, a boot test will be performed."
    echo "  Resume Bisection: Provide -i to resume a previously started bisection."
    echo ""
    echo "Options:"
    echo "  -pb,  --platform-build <url|path|none>"
    echo "                                   A platform build. To bisect, use a range format."
    echo "                                   Format: ab://<branch>/<target>/<id1>-<id2> OR ab://.../<id1,id2,...>"
    echo "                                   Can be set to 'none' for physical devices to skip flashing."
    echo "  -kb,  --kernel-build, -gki, --gki-build <url|path|none>"
    echo "                                   A kernel build. To bisect, use a range format."
    echo "                                   Can be set to 'none' for physical devices to skip flashing."
    echo "  -vkb, --vendor-kernel-build <url|path|none>"
    echo "                                   A vendor kernel build. To bisect, use a range format."
    echo "                                   Can be set to 'none' for physical devices to skip flashing."
    echo "  -sb,  --system-build, -gsi, --gsi-build <url|path|none>"
    echo "                                   A system (GSI) build. To bisect, use a range format."
    echo "                                   Can be set to 'none' for physical devices to skip flashing."
    echo "  -s,   --serial-number <serial>   The physical device serial. If omitted, uses a Cuttlefish virtual device."
    echo "  -t,   --test <name>              [Optional] The test name(s) to run. Can be repeated. If omitted, runs a boot test."
    echo "  -td, --test-dir, -tb, --test-suite-build <url|path>"
    echo "                                   Path to test artifacts or an ab:// URL to download or bisect them."
    echo "                                   Required only if -t is provided."
    echo "  -tr,  --test-retry <count>       Retry count for a failed test. Default: ${DEFAULT_TEST_RETRY}."
    echo "  -sr,  --setup-retry <count>      Retry count for failed device setup. Default: ${DEFAULT_SETUP_RETRY}."
    echo "  --skip-build                     [Optional] If set, pass '--skip-build' to underlying flash/launch scripts."
    echo "  --dry-run                        [Optional] Initialize the bisection XML file and exit without running tests."
    echo "  -od,  --output-dir <path>        Path of Directory to store the bisection state XML file. Default: ${DEFAULT_OUTPUT_DIR}/${DEFAULT_BISECT_CONFIG_FILENAME}."
    echo "  -i,   --input-config-file <path> Resume bisection from the given state XML file."
    echo "  -h,   --help                     Display this help message."
    echo ""
    echo "Examples:"
    echo "  # Bisect both platform and kernel builds simultaneously"
    echo "  $0 -pb ab://git_main/oriole-userdebug/120000-130000 \\"
    echo "     -kb ab://git_main/oriole-userdebug/50000-51000 \\"
    echo "     -t CtsMyModuleTest -td /path/to/android-cts.zip"
    echo ""
    echo "  # Start bisection using a specific list of kernel builds on a physical device"
    echo "  $0 -kb ab://git_main/oriole-userdebug/120000,120005,120010 -pb ab://.../130000 \\"
    echo "     -s 1A2B3C4D -t CtsMyModuleTest -td /path/to/android-cts.zip"
    echo ""
    echo "  # Resume an interrupted bisection"
    echo "  $0 -i bisect_builds.xml"
}

function parse_args() {
    local has_input_file=false
    local has_new_bisect_args=false

    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                print_help
                exit $EXIT_SUCCESS
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
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                log_error "Unsupported flag: $1"
                print_help
                exit $EXIT_FAILURE
                ;;
        esac
    done

    if [[ "$has_input_file" == true && ! -f "$INPUT_CONFIG_FILE" ]]; then
        fail_error "Input config file not found: $INPUT_CONFIG_FILE"
    fi

    if "$has_input_file" && "$has_new_bisect_args"; then
        fail_error "Cannot specify new bisection options (-pb, -kb, etc.) when resuming with -i."
    fi

    if "$has_input_file" && "$DRY_RUN"; then
        fail_error "Cannot specify --dry-run when resuming with -i."
    fi

    if ! "$has_input_file"; then
        if (( ${#TEST_NAME[@]} == 0 )); then
             log_info "No -t parameter specified. Performing a boot test."
        elif [[ -z "$TEST_SUITE_BUILD" ]]; then
             fail_error "For a new test bisection, --test-dir|--test-suite-build (-td|-tb) must be specified when --test (-t) is provided."
        fi
    fi
}

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

function is_test_suite_fixed() {
    local required_locator="$1"

    if [[ -z "$required_locator" ]]; then
        if (( ${#TEST_NAME[@]} == 0 )); then
            return $EXIT_SUCCESS
        fi
        fail_error "Test suite is required for any combination."
    fi

    if [[ "$required_locator" != "$CURRENT_TEST_SUITE_LOCATOR" ]]; then
        log_info "The new ${required_locator} is different from the last one."
        return $EXIT_FAILURE
    fi

    log_info "Required test suite is already prepared. Skipping."
    return $EXIT_SUCCESS
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

function validate_args() {
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
    fi
    OUTPUT_DIR=$(realpath "$OUTPUT_DIR")
    BISECT_CONFIG_FILE="${OUTPUT_DIR}/${DEFAULT_BISECT_CONFIG_FILENAME}"

    if [[ -n "$INPUT_CONFIG_FILE" ]]; then
        return $EXIT_SUCCESS
    fi

    # Determine device type for validation
    local current_device_type="VIRTUAL"
    if [[ -n "$SERIAL_NUMBER" ]]; then
        current_device_type="PHYSICAL"
    fi

    # --- New Bisection Validations ---
    local bisect_arg_found=false
    local -a original_ranged_types=()
    local -A ORIG_BRANCHES=()
    local -A ORIG_TARGETS=()
    local -A ORIG_BUILDS=()
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local build_value="${!var_name}"
        if [[ -z "$build_value" ]]; then
            continue
        fi

        local branch target filename
        local -a ids=()
        local id_type=""
        parse_build_string "$build_value" branch target ids id_type filename

        if [[ "$id_type" == "none" ]]; then
            if [[ "$type_code" == "tb" ]]; then
                fail_error "Test suite ('tb') cannot be set to 'none'."
            fi
            if [[ "$current_device_type" != "PHYSICAL" ]]; then
                fail_error "Setting build to 'none' is only supported for Physical Devices (with -s)."
            fi
        fi

        # Store details for all provided build types
        ID_TYPES[$type_code]="$id_type"
        BRANCHES[$type_code]="$branch"
        TARGETS[$type_code]="$target"
        FILENAMES[$type_code]="$filename"

        if [[ "$id_type" == "range" || "$id_type" == "list" ]]; then
            local -a build_ids_to_test=()
            if [[ "$id_type" == "range" ]]; then
                get_build_ids "$branch" "$target" "${ids[0]}" "${ids[1]}" build_ids_to_test
            else # list
                build_ids_to_test=("${ids[@]}")
            fi

            if (( ${#build_ids_to_test[@]} == 1 )); then
                 log_warn "Range for '$type_code' only contains 1 build (${build_ids_to_test[0]}). Treating it as a fixed single build."

                 original_ranged_types+=("$type_code")
                 ORIG_BRANCHES[$type_code]="$branch"
                 ORIG_TARGETS[$type_code]="$target"
                 ORIG_BUILDS[$type_code]="${build_ids_to_test[0]}"

                 id_type="single"
                 ID_TYPES[$type_code]="single"

                 # Re-set and cleanup public array state to prevent confusion during debugging
                 unset "BRANCHES[$type_code]"
                 unset "TARGETS[$type_code]"
                 unset "FILENAMES[$type_code]"

                 # Reconstruct the URL for the single build
                 local new_url="ab://${branch}/${target}/${build_ids_to_test[0]}"
                 if [[ "$type_code" == "tb" && -n "$filename" ]]; then
                     new_url="${new_url}/${filename}"
                 fi
                 printf -v "$var_name" "%s" "$new_url"
            elif (( ${#build_ids_to_test[@]} == 0 )); then
                 fail_error "No builds found for '$type_code'."
            else
                 bisect_arg_found=true
                 if [[ "$type_code" == "tb" && -z "$filename" ]]; then
                     fail_error "Test suite ('tb') bisection requires a filename in the URL (e.g., .../range/android-cts.zip)."
                 fi
                 # Store the array as a space-separated string in the map
                 BUILDS_TO_TEST_MAP[$type_code]="${build_ids_to_test[*]}"
            fi
        fi
    done

    if ! "$bisect_arg_found"; then
        log_info "No valid bisection ranges found (all provided ranges resolved to single builds). Falling back to setup_and_test.sh..."
        local -a fallback_args=()
        [[ -n "$PLATFORM_BUILD" ]] && fallback_args+=("-pb" "$PLATFORM_BUILD")
        [[ -n "$KERNEL_BUILD" ]] && fallback_args+=("-kb" "$KERNEL_BUILD")
        [[ -n "$VENDOR_KERNEL_BUILD" ]] && fallback_args+=("-vkb" "$VENDOR_KERNEL_BUILD")
        [[ -n "$GSI_BUILD" ]] && fallback_args+=("-sb" "$GSI_BUILD")
        [[ -n "$TEST_SUITE_BUILD" ]] && fallback_args+=("-tb" "$TEST_SUITE_BUILD")
        [[ -n "$SERIAL_NUMBER" ]] && fallback_args+=("-s" "$SERIAL_NUMBER")
        [[ -n "$OUTPUT_DIR" ]] && fallback_args+=("-od" "$OUTPUT_DIR")
        fallback_args+=("-tr" "$TEST_RETRY" "-sr" "$SETUP_RETRY")
        for test in "${TEST_NAME[@]}"; do fallback_args+=("-t" "$test"); done

        # Execute setup_and_test.sh and exit with its code
        "${SETUP_AND_TEST_SCRIPT}" "${fallback_args[@]}"
        local fallback_status=$?

        if (( fallback_status != 0 )); then
            echo ""
            log_warn "========================================="
            log_warn "Fallback test execution FAILED."
            log_warn "========================================="
            for type_code in "${original_ranged_types[@]}"; do
                local first_build_id="${ORIG_BUILDS[$type_code]}"

                echo ""
                log_info "--- Commit info for initial build of ${BUILD_TYPE_MAP[$type_code]} ($type_code): $first_build_id ---"
                print_commit_ranges_for_build "$first_build_id"
                print_fallback_commit_bisection_command "$type_code"
            done
            echo ""
            fail_error "Fallback test execution failed. (Exit Code $fallback_status)" "$fallback_status"
        fi

        exit $fallback_status
    fi

    # Handle a fixed test suite URL if we are NOT bisecting the test suite itself.
    if [[ "${ID_TYPES[tb]}" != "range" && "${ID_TYPES[tb]}" != "list" && -n "$TEST_SUITE_BUILD" && ${#TEST_NAME[@]} > 0 ]]; then
        prepare_test_suite "$TEST_SUITE_BUILD"
    fi
}

function fail_error() {
    local message="$1"
    local exit_code="${2:-$EXIT_FAILURE}"
    # Pass frame offset 2 to log_error to point to the caller of fail_error
    log_error "$message" "$exit_code" 2
    exit "$exit_code"
}

function extract_build_ids_from_file() {
    local filename="$1"
    if [[ ! -f "$filename" ]]; then
        fail_error "Error: File '${filename}' not found."
    fi

    awk -F',' '
        NR > 1 {
            gsub(/"/, "", $1);
            print $1;
        }
    ' "$filename"
}

function get_build_ids() {
    local branch="$1"
    local target="$2"
    local start_id="$3"
    local end_id="$4"
    local -n result_array_ref="$5"

    log_info "Fetching all build IDs for $target from $start_id to $end_id..."

    if ! "$QUERY_BUILD_SCRIPT" -br "${branch}" -bt "${target}" -sbid "${start_id}" -ebid "${end_id}"; then
        fail_error "Error running query_build.sh. branch: ${branch}, build_target: ${target}"
    fi

    local queryfile="/tmp/build_query_output.csv"
    local -a unsorted_build_ids_array
    mapfile -t unsorted_build_ids_array < <(extract_build_ids_from_file "$queryfile")
    mapfile -t result_array_ref < <(printf "%s\n" "${unsorted_build_ids_array[@]}" | sort -n)

    if (( ${#result_array_ref[@]} == 0 )); then
        fail_error "Could not find any builds between ${start_id} and ${end_id} for target ${target} on branch ${branch}."
    fi
    log_info "Found ${#result_array_ref[@]} builds to test for ${target}."
}

function init_bisect_file() {
    log_info "Initializing new bisection state file: $BISECT_CONFIG_FILE"
    xml_util::init "$BISECT_CONFIG_FILE" "bisect" || fail_error "Failed to initialize XML file: $BISECT_CONFIG_FILE"

    local -a xml_edit_cmd=("xmlstarlet" "ed" "-L")

    # State node
    xml_util::add_node       xml_edit_cmd "/bisect" "state"
    xml_util::add_attribute  xml_edit_cmd "/bisect/state" "status" "new"

    # Parameters node
    xml_util::add_node       xml_edit_cmd "/bisect" "parameters"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "test_dir"      "$TEST_DIR"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "output_dir"    "$OUTPUT_DIR"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "test_retry"    "$TEST_RETRY"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "setup_retry"   "$SETUP_RETRY"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "serial_number" "$SERIAL_NUMBER"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "skip_build"    "$SKIP_BUILD"
    for test in "${TEST_NAME[@]}"; do
        xml_util::add_element xml_edit_cmd "/bisect/parameters" "test" "$test"
    done

    # Add nodes for ALL build types provided
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local build_value="${!var_name}"

        if [[ -z "$build_value" ]]; then
            continue
        fi

        if [[ "${ID_TYPES[$type_code]}" == "list" || "${ID_TYPES[$type_code]}" == "range" ]]; then
            # This is a build type being bisected
            local node_name="${var_name,,}s" # e.g., platform_builds
            xml_util::add_node       xml_edit_cmd "/bisect" "$node_name"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$node_name" "id_type" "${ID_TYPES[$type_code]}"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$node_name" "branch" "${BRANCHES[$type_code]}"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$node_name" "target" "${TARGETS[$type_code]}"
            if [[ "$type_code" == "tb" ]]; then
                xml_util::add_attribute xml_edit_cmd "/bisect/$node_name" "filename" "${FILENAMES[$type_code]}"
            fi
            # Read build IDs from the map string
            local -a build_ids_arr=(${BUILDS_TO_TEST_MAP[$type_code]})
            for index in "${!build_ids_arr[@]}"; do
                xpath_idx=$((index + 1))
                build_id="${build_ids_arr[$index]}"
                xml_util::add_element xml_edit_cmd "/bisect/$node_name" "build" "$build_id"
                xml_util::add_attribute xml_edit_cmd "/bisect/$node_name/build[${xpath_idx}]" "index" "$index"
            done
        else
            # This is a fixed build (single, local, or none)
            local single_node_name="${var_name,,}" # e.g., platform_build
            xml_util::add_node       xml_edit_cmd "/bisect" "$single_node_name"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$single_node_name" "id_type" "${ID_TYPES[$type_code]}"
            # Set the value of the node
            xml_edit_cmd+=(-u "/bisect/$single_node_name" -v "$build_value")
        fi
    done

    # Execute the command with error handling
    "${xml_edit_cmd[@]}" "$BISECT_CONFIG_FILE" || fail_error "Failed to populate initial bisection XML data."
}

function load_state_from_xml() {
    log_info "Loading state from ${BISECT_CONFIG_FILE}..."
    BISECT_STATUS=$(xml_util::read_value "/bisect/state/@status")

    # Parameters
    TEST_DIR=$(xml_util::read_value "/bisect/parameters/@test_dir")
    OUTPUT_DIR=$(xml_util::read_value "/bisect/parameters/@output_dir")
    TEST_RETRY=$(xml_util::read_value "/bisect/parameters/@test_retry")
    SETUP_RETRY=$(xml_util::read_value "/bisect/parameters/@setup_retry")
    SERIAL_NUMBER=$(xml_util::read_value "/bisect/parameters/@serial_number")
    SKIP_BUILD=$(xml_util::read_value "/bisect/parameters/@skip_build")
    xml_util::read_values_to_array "/bisect/parameters/test" TEST_NAME

    # Load all build types from XML
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local plural_node_name="${var_name,,}s" # e.g., platform_builds
        local single_node_name="${var_name,,}" # e.g., platform_build

        # Check for a bisection node (plural form) first
        local id_type=$(xml_util::read_value "/bisect/$plural_node_name/@id_type")
        if [[ "$id_type" == "range" || "$id_type" == "list" ]]; then
            ID_TYPES[$type_code]="$id_type"
            BRANCHES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@branch")
            TARGETS[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@target")
            FILENAMES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@filename")
            GOOD_INDICES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@good_index")
            BAD_INDICES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@bad_index")
            IS_BREAKING[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@is_breaking")

            local -a builds_arr=()
            xml_util::read_values_to_array "/bisect/$plural_node_name/build" builds_arr
            BUILDS_TO_TEST_MAP[$type_code]="${builds_arr[*]}"

            if [[ "${IS_BREAKING[$type_code]}" == "true" ]]; then
                BISECT_BUILD_TYPES+=("$type_code")
            fi
        else
            # Check for a fixed build node (singular form)
            id_type=$(xml_util::read_value "/bisect/$single_node_name/@id_type")
            if [[ -n "$id_type" ]]; then
                local build_val
                build_val=$(xml_util::read_value "/bisect/$single_node_name")
                if [[ -n "$build_val" ]]; then
                    ID_TYPES[$type_code]="$id_type"
                    # Dynamically set the global variable (e.g., PLATFORM_BUILD)
                    printf -v "$var_name" "%s" "$build_val"
                fi
            fi
        fi
    done
    log_info "State loaded successfully. Status: $BISECT_STATUS"
}

function resolve_build_locator() {
    local type_code="$1"
    local locator="$2" # This can be a build ID, a full URL, or a local path.

    # If locator is a number, it's a build ID that needs to be resolved to a full URL.
    if [[ "$locator" =~ ^[0-9]+$ ]]; then
        local url="ab://${BRANCHES[$type_code]}/${TARGETS[$type_code]}/${locator}"
        if [[ "$type_code" == "tb" ]]; then
            url+="/${FILENAMES[$type_code]}"
        fi
        echo "$url"
    else
        # Otherwise, the locator is already a full URL, a local path, or 'none'. Return it directly.
        echo "$locator"
    fi
}

function setup_and_test_combination() {
    # This function takes a series of key-value pairs like "pb:12345", "kb:54321", or "tb:/local/path"
    # It assembles the full device setup command and runs the test.
    local -A locators_to_use
    for arg in "$@"; do
        local type_code="${arg%%:*}"
        # The remainder of the string is the locator
        local locator="${arg#*:}"
        locators_to_use[$type_code]="$locator"
    done

    local current_pb="" current_kb="" current_vkb="" current_sb="" current_tb_locator=""

    # Construct URLs for all provided build types
    for type_code in "${!locators_to_use[@]}"; do
        local locator="${locators_to_use[$type_code]}"
        local url
        url=$(resolve_build_locator "$type_code" "$locator")

        case "$type_code" in
            pb) current_pb="$url" ;;
            kb) current_kb="$url" ;;
            vkb) current_vkb="$url" ;;
            sb) current_sb="$url" ;;
            tb) current_tb_locator="$url" ;;
        esac
    done

    local pb_type="${ID_TYPES[pb]}"
    if [[ "$DEVICE_TYPE" == "PHYSICAL" && "$HAS_FLASHED_PB" == "true" && ("$pb_type" == "single" || "$pb_type" == "local" || "$pb_type" == "none") ]]; then
        log_info "Optimization: PB is fixed and already flashed in this session. Setting current_pb to 'none' to skip re-flashing."
        current_pb="none"
    fi

    if (( ${#TEST_NAME[@]} > 0 )); then
        if ! is_test_suite_fixed "$current_tb_locator"; then
            prepare_test_suite "$current_tb_locator"
            CURRENT_TEST_SUITE_LOCATOR="$current_tb_locator"
            xml_util::update_xml_attribute "/bisect/parameters" "test_dir" "$TEST_DIR"
        fi
    fi

    perform_device_setup "$current_pb" "$current_kb" "$current_vkb" "$current_sb"
    local setup_status=$?
    if (( setup_status != 0 )); then
        log_warn "Device setup failed. Returning error status $setup_status."
        return $EXIT_SETUP_FAILED
    fi

    if [[ "$current_pb" != "none" && -n "$current_pb" ]]; then
        HAS_FLASHED_PB=true
        log_info "HAS_FLASHED_PB set to true for the current session."
    fi

    if (( ${#TEST_NAME[@]} == 0 )); then
        log_info "Boot test PASSED for this combination."
        return $TEST_PASSED
    fi

    run_tests_on_device
    return $?
}

function perform_device_setup() {
    local pb="$1" kb="$2" vkb="$3" sb="$4"

    local -a setup_cmd_array=()
    if [[ "$DEVICE_TYPE" == "PHYSICAL" ]]; then
        setup_cmd_array=("$FLASH_DEVICE_SCRIPT" "-s" "$SERIAL_NUMBER")
        [[ -n "$pb" ]] && setup_cmd_array+=("-pb" "$pb")
        [[ -n "$kb" ]] && setup_cmd_array+=("-kb" "$kb")
        [[ -n "$vkb" ]] && setup_cmd_array+=("-vkb" "$vkb")
        [[ -n "$sb" ]] && setup_cmd_array+=("-sb" "$sb")
    elif [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        # Connect Cuttlefish with adb connection only. Skip webrtc autoconnect
        setup_cmd_array=("$LAUNCH_CVD_SCRIPT" "--acloud-arg=--autoconnect" "--acloud-arg=adb" "--serial-out" "$ACLOUD_OUTPUT_FILE")
        [[ -n "$pb" ]] && setup_cmd_array+=("-pb" "$pb")
        [[ -n "$kb" ]] && setup_cmd_array+=("-kb" "$kb")
        [[ -n "$sb" ]] && setup_cmd_array+=("-sb" "$sb")
        # launch_cvd does not support vkb
    else
        fail_error "The Device Type Option not supported: ${DEVICE_TYPE}"
    fi
    if "$SKIP_BUILD"; then
        setup_cmd_array+=("--skip-build")
    fi

    log_info "Executing device setup: ${setup_cmd_array[*]}"
    local setup_success=false
    for i in $(seq 1 "$SETUP_RETRY"); do
        local setup_status=1
        "${setup_cmd_array[@]}"
        setup_status=$?

        if (( setup_status == 0 )); then
            setup_success=true
            break
        fi
        log_warn "Setup failed (Attempt $i/$SETUP_RETRY). Retrying..."
        sleep 10
    done

    if ! "$setup_success"; then
        log_error "Device setup failed after $SETUP_RETRY attempts."
        return $EXIT_SETUP_FAILED
    fi

    log_info "Device setup successful."
    return $EXIT_SUCCESS
}

function run_tests_on_device() {
    local input_serial_to_use="$SERIAL_NUMBER"
    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        if [[ -f "$ACLOUD_OUTPUT_FILE" ]]; then
            input_serial_to_use=$(cat "$ACLOUD_OUTPUT_FILE")
        fi
        if [[ -z "$input_serial_to_use" ]]; then
             log_error "Could not determine virtual device serial from output file."
             return $EXIT_FAILURE
        fi
    fi

    if ! device_util::init "$input_serial_to_use"; then
        return $EXIT_FAILURE
    fi
    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        device_util::wait_for_boot_complete || return $EXIT_FAILURE
    else
        # Physical devices
        device_util::unlock_screen || return $EXIT_FAILURE
        device_util::skip_setup_wizard || return $EXIT_FAILURE
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
            return $TEST_PASSED
        fi
        log_warn "Test failed (Attempt $i/$TEST_RETRY). Retrying..."
    done

    log_warn "Test FAILED after $TEST_RETRY attempts."
    return $TEST_FAILED
}

function validate_initial_builds() {
    log_info "--- Step 1: Validating the initial 'all good' build combination ---"
    local -a ranged_build_types=()
    local -a initial_good_combination=()

    # Collect all build types that have a range/list
    for type_code in "${!ID_TYPES[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "range" || "${ID_TYPES[$type_code]}" == "list" ]]; then
            ranged_build_types+=("$type_code")
        fi
    done

    # Add fixed builds to the combination
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" != "range" && "${ID_TYPES[$type_code]}" != "list" ]]; then
             local var_name="${BUILD_TYPE_MAP[$type_code]}"
             if [[ -n "${!var_name}" ]]; then
                initial_good_combination+=("${type_code}:${!var_name}")
             fi
        fi
    done

    # Get the FIRST build ID from each ranged build type
    for type_code in "${ranged_build_types[@]}"; do
        local -a builds=(${BUILDS_TO_TEST_MAP[$type_code]})
        initial_good_combination+=("${type_code}:${builds[0]}")
    done

    log_info "Testing with initial good combination: ${initial_good_combination[*]}"
    setup_and_test_combination "${initial_good_combination[@]}"
    local init_status=$?
    if (( init_status != 0 )); then
        echo ""
        log_warn "========================================="
        log_warn "Initial 'all good' combination FAILED."
        log_warn "========================================="
        for type_code in "${ranged_build_types[@]}"; do
            local -a builds=(${BUILDS_TO_TEST_MAP[$type_code]})
            local first_build_id="${builds[0]}"

            echo ""
            log_info "--- Commit info for initial build of ${BUILD_TYPE_MAP[$type_code]} ($type_code): $first_build_id ---"
            print_commit_ranges_for_build "$first_build_id"
            print_fallback_commit_bisection_command "$type_code"
        done
        echo ""
        fail_error "Validation failed: The combination of the FIRST builds in all ranges is FAILING the test (or setup)."
    fi
    log_info "Initial 'all good' combination PASSED."

    log_info "--- Step 2: Iteratively identifying breaking build types ---"
    # Iterate in the specified priority order
    for type_to_check in "${BISECT_ORDER[@]}"; do
        # Only check types that were provided with a range/list
        if [[ "${ID_TYPES[$type_to_check]}" != "range" && "${ID_TYPES[$type_to_check]}" != "list" ]]; then
            continue
        fi

        local -a breaking_test_combination=()
        local -a builds_for_type=(${BUILDS_TO_TEST_MAP[$type_to_check]})
        local last_build_index=$(( ${#builds_for_type[@]} - 1 ))

        # Use LAST build of the type we are checking
        breaking_test_combination+=("${type_to_check}:${builds_for_type[$last_build_index]}")

        # Use FIRST build of all OTHER ranged types
        for other_type in "${ranged_build_types[@]}"; do
            if [[ "$other_type" != "$type_to_check" ]]; then
                local -a other_builds=(${BUILDS_TO_TEST_MAP[$other_type]})
                breaking_test_combination+=("${other_type}:${other_builds[0]}")
            fi
        done
        # Add fixed builds
        for type_code in "${!BUILD_TYPE_MAP[@]}"; do
            if [[ "${ID_TYPES[$type_code]}" != "range" && "${ID_TYPES[$type_code]}" != "list" ]]; then
                local var_name="${BUILD_TYPE_MAP[$type_code]}"
                if [[ -n "${!var_name}" ]]; then
                    breaking_test_combination+=("${type_code}:${!var_name}")
                fi
            fi
        done

        log_info "Checking for breakage in '${type_to_check}' using combination: ${breaking_test_combination[*]}"
        setup_and_test_combination "${breaking_test_combination[@]}"
        local test_status=$?

        local var_name="${BUILD_TYPE_MAP[$type_to_check]}"
        local node_name="${var_name,,}s"
        if (( test_status != 0 )); then
            log_info "RESULT: Found breaking build type: ${type_to_check}"
            BISECT_BUILD_TYPES+=("$type_to_check")
            local -a builds=(${BUILDS_TO_TEST_MAP[$type_to_check]})
            GOOD_INDICES[$type_to_check]=0
            BAD_INDICES[$type_to_check]=$(( ${#builds[@]} - 1 ))
            IS_BREAKING[$type_to_check]=true

            # Update XML state for this breaking build
            xml_util::update_xml_attribute "/bisect/$node_name" "good_index" "0"
            xml_util::update_xml_attribute "/bisect/$node_name" "bad_index" "${BAD_INDICES[$type_to_check]}"
            xml_util::update_xml_attribute "/bisect/$node_name" "is_breaking" "true"

            if (( test_status == EXIT_SETUP_FAILED )) && (( ${#TEST_NAME[@]} > 0 )); then
                fail_error "Setup failed. BAD_INDEX has been updated in the XML file before exiting."
            fi
        else
            log_info "RESULT: Build type '${type_to_check}' is NOT identified as breaking."
            IS_BREAKING[$type_to_check]=false
            xml_util::update_xml_attribute "/bisect/$node_name" "is_breaking" "false"
        fi
    done

    log_info "--- Step 3: Final validation check ---"
    if (( ${#BISECT_BUILD_TYPES[@]} == 0 )); then
        fail_error "Validation failed: No breaking build types were identified. The combination of all LAST builds seems to be passing."
    fi

    log_info "Validation complete. Breaking build types to be bisected: ${BISECT_BUILD_TYPES[*]}"
}

function determine_default_device_type() {
    if [[ -n "$SERIAL_NUMBER" ]]; then
        DEVICE_TYPE="PHYSICAL"
    else
        DEVICE_TYPE="VIRTUAL"
    fi
    log_info "Determined the Default Device Type: $DEVICE_TYPE"
}

function cleanup() {
    log_info "Cleaning up temporary files and directories..."
    if (( ${#TEMP_FILES[@]} > 0 )); then
        rm -f "${TEMP_FILES[@]}"
    fi
    if (( ${#TEMP_DIRS[@]} > 0 )); then
        rm -rf "${TEMP_DIRS[@]}"
    fi
}

function bisect_single_build_type() {
    local type_code_to_bisect="$1"
    log_info "========================================="
    log_info "Starting Bisection Loop for: $type_code_to_bisect"
    log_info "========================================="

    local good_idx=${GOOD_INDICES[$type_code_to_bisect]}
    local bad_idx=${BAD_INDICES[$type_code_to_bisect]}
    local -a builds_to_test=(${BUILDS_TO_TEST_MAP[$type_code_to_bisect]})

    local var_name="${BUILD_TYPE_MAP[$type_code_to_bisect]}"
    local node_name="${var_name,,}s"

    while (( good_idx + 1 < bad_idx )); do
        local mid_idx=$(( good_idx + (bad_idx - good_idx) / 2 ))
        local mid_build_id=${builds_to_test[$mid_idx]}

        log_info "--- Testing $type_code_to_bisect at index: $mid_idx (ID: $mid_build_id) ---"

        local -a test_combination=()
        # Add the mid build for the type we are currently bisecting
        test_combination+=("${type_code_to_bisect}:${mid_build_id}")

        # For all other build types, add their stable baseline build to the combination
        for other_type in "${!BUILD_TYPE_MAP[@]}"; do
            if [[ "$other_type" == "$type_code_to_bisect" || -z "${ID_TYPES[$other_type]}" ]]; then
                continue # Skip the type we're bisecting or any type not in use
            fi

            if [[ "${ID_TYPES[$other_type]}" == "range" || "${ID_TYPES[$other_type]}" == "list" ]]; then
                # It's a ranged build. Use its first (known good) build as the stable baseline.
                local -a other_builds=(${BUILDS_TO_TEST_MAP[$other_type]})
                test_combination+=("${other_type}:${other_builds[0]}")
            else
                # It's a fixed build (single, local, or none). Use its full value.
                local other_var_name="${BUILD_TYPE_MAP[$other_type]}"
                if [[ -n "${!other_var_name}" ]]; then
                   test_combination+=("${other_type}:${!other_var_name}")
                fi
            fi
        done

        log_info "Testing with combination: ${test_combination[*]}"
        setup_and_test_combination "${test_combination[@]}"
        local test_status=$?

        if (( test_status == 0 )); then
            log_info "RESULT: Build $mid_build_id ($type_code_to_bisect) is GOOD."
            good_idx=$mid_idx
            GOOD_INDICES[$type_code_to_bisect]=$good_idx
            xml_util::update_xml_attribute "/bisect/$node_name" "good_index" "$good_idx"
        else
            log_info "RESULT: Build $mid_build_id ($type_code_to_bisect) is BAD."
            bad_idx=$mid_idx
            BAD_INDICES[$type_code_to_bisect]=$bad_idx
            xml_util::update_xml_attribute "/bisect/$node_name" "bad_index" "$bad_idx"

            if (( test_status == EXIT_SETUP_FAILED )) && (( ${#TEST_NAME[@]} > 0 )); then
                fail_error "Setup failed. BAD_INDEX has been updated in the XML file before exiting."
            fi
        fi
        log_info "New Range for $type_code_to_bisect: Index $good_idx (Good) to $bad_idx (Bad)"
    done
}

function print_commit_ranges_for_build() {
    PROJECTS_WITH_CHANGES=()
    PROJECT_COMMIT_RANGES=()

    local build_id="$1"
    if [[ -z "$build_id" ]]; then
        return
    fi

    local changes_csv="$OUTPUT_DIR/changes_${build_id}.csv"
    log_info "Querying changes for bad build ${build_id}..."
    if "$QUERY_CHANGE_SCRIPT" -bid "$build_id" -o "$changes_csv" &>/dev/null; then
        if [[ -f "$changes_csv" ]]; then
            log_info "Commit ID range for each project in build ${build_id}:"
            while IFS='|' read -r project range; do
                if [[ -z "$project" ]]; then
                    continue
                fi
                PROJECTS_WITH_CHANGES+=("$project")
                PROJECT_COMMIT_RANGES["$project"]="$range"
                if [[ "$range" == *"-"* ]]; then
                    log_info "  Project: $project, Commit Range: $range"
                else
                    log_info "  Project: $project, Commit: $range"
                fi
                if [[ "$project" == "kernel/common" ]]; then
                    log_info " Please try kernel/tests/tools/find_change_breakage.sh with -kb <your_local_source_code>/common:$range"
                fi
            done < <(awk -F',' '
                NR > 1 {
                    gsub(/"/, "", $2);
                    gsub(/"/, "", $4);
                    commit = $2;
                    project = $4;
                    if (project != "" && commit != "") {
                        if (!(project in first_commit)) {
                            first_commit[project] = commit;
                            projects[num_projects++] = project;
                        }
                        last_commit[project] = commit;
                    }
                }
                END {
                    for (i = 0; i < num_projects; i++) {
                        p = projects[i];
                        if (first_commit[p] == last_commit[p]) {
                            printf "%s|%s\n", p, first_commit[p];
                        } else {
                            printf "%s|%s-%s\n", p, first_commit[p], last_commit[p];
                        }
                    }
                }
            ' "$changes_csv")
        fi
    else
        log_warn "Failed to query changes for build ${build_id}."
    fi
}

function print_fallback_commit_bisection_command() {
    local target_type_code="$1"

    local -a other_args=()
    for key in "${!BUILD_TYPE_MAP[@]}"; do
        if [[ "$key" == "$target_type_code" ]]; then
            continue
        fi

        local var_name="${BUILD_TYPE_MAP[$key]}"
        local original_build_string="${!var_name}"
        if [[ -z "$original_build_string" ]]; then
            continue
        fi

        other_args+=("-${key}" "${original_build_string}")
    done

    if (( ${#PROJECTS_WITH_CHANGES[@]} == 0 )); then
        log_warn "No project changes found to bisect."
        return
    fi

    for project in "${PROJECTS_WITH_CHANGES[@]}"; do
        local commit_range="${PROJECT_COMMIT_RANGES[$project]}"
        local project_sanitized="${project//\//_}"

        echo ""
        log_info "To bisect commits for project '$project' in ${BUILD_TYPE_MAP[$target_type_code]} ($target_type_code), run:"
        echo -e "\n${SCRIPT_DIR}/find_change_breakage.sh -${target_type_code} <YOUR_ANDROID_TREE_PATH>/${project}:${commit_range} ${other_args[@]}\n"
    done
}

function print_commit_bisection_instruction() {
    local type_code="$1"
    local last_good_id="$2"
    local first_bad_id="$3"

    local b_branch="${BRANCHES[$type_code]}"
    local b_target="${TARGETS[$type_code]}"
    local -a commit_bisection_args=()

    for key in "${!BUILD_TYPE_MAP[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$key]}"
        local original_build_string="${!var_name}"

        if [[ -z "$original_build_string" ]]; then
            continue
        fi

        if [[ "$key" == "$type_code" ]]; then
            # This is the breaking type, we use manifest_diff syntax
            local fake_tree="${HOME}/${type_code}-${b_branch}-${b_target}"
            commit_bisection_args+=("-${key}" "${fake_tree}:ab://${b_branch}/${b_target}/${last_good_id}-${first_bad_id}")
        else
            # Other types: use their fixed build string or last_good_id
            if [[ -n "${BUILDS_TO_TEST_MAP[$key]:-}" ]]; then
                # It participated in build bisection, but is not the breaking target here, so we use its last good_id (or 0 if not yet set)
                local other_good_idx=${GOOD_INDICES[$key]:-0}
                local -a other_builds=(${BUILDS_TO_TEST_MAP[$key]})
                local other_good_id=${other_builds[$other_good_idx]}
                local other_good_url=$(resolve_build_locator "$key" "$other_good_id")
                commit_bisection_args+=("-${key}" "$other_good_url")
            else
                # Did not participate in bisection (user provided fixed local/remote path)
                commit_bisection_args+=("-${key}" "${original_build_string}")
            fi
        fi
    done

    # Add Test parameters and additional output directory
    for t in "${TEST_NAME[@]}"; do
        commit_bisection_args+=("-t" "$t")
    done
    if [[ -n "${SERIAL_NUMBER:-}" ]]; then
        commit_bisection_args+=("-s" "$SERIAL_NUMBER")
    fi
    if [[ "${TEST_RETRY:-$DEFAULT_TEST_RETRY}" != "$DEFAULT_TEST_RETRY" ]]; then
        commit_bisection_args+=("-tr" "$TEST_RETRY")
    fi
    if [[ "${SETUP_RETRY:-$DEFAULT_SETUP_RETRY}" != "$DEFAULT_SETUP_RETRY" ]]; then
        commit_bisection_args+=("-sr" "$SETUP_RETRY")
    fi
    if [[ "${SKIP_BUILD:-false}" == true ]]; then
        commit_bisection_args+=("--skip-build")
    fi

    commit_bisection_args+=("-od" "${OUTPUT_DIR}/${type_code}")

    echo ""
    log_info "Found build breakage for ${BUILD_TYPE_MAP[$type_code]} ($type_code)."
    log_info "To find the exact breaking commit, please run the following command:"

    local cmd_str="$FIND_CHANGE_BREAKAGE_SCRIPT"
    local arg
    for arg in "${commit_bisection_args[@]}"; do
        printf -v cmd_str "%s %q" "$cmd_str" "$arg"
    done

    log_info " $cmd_str"
}

function bisect_all_breaking_builds() {
    # Bisect each breaking build type in the specified order
    for type_code in "${BISECT_ORDER[@]}"; do
        if [[ " ${BISECT_BUILD_TYPES[*]} " =~ " ${type_code} " ]]; then
            bisect_single_build_type "$type_code"
        fi
    done

    log_info "========================================="
    log_info "All Bisections Complete!"
    log_info "========================================="
    xml_util::update_xml_node "/bisect/state/@status" "complete"

    for type_code in "${BISECT_BUILD_TYPES[@]}"; do
        local good_idx=${GOOD_INDICES[$type_code]}
        local bad_idx=${BAD_INDICES[$type_code]}
        local -a builds=(${BUILDS_TO_TEST_MAP[$type_code]})

        local last_good_id=${builds[$good_idx]}
        local first_bad_id=${builds[$bad_idx]}

        local last_good_url=$(resolve_build_locator "$type_code" "$last_good_id")
        local first_bad_url=$(resolve_build_locator "$type_code" "$first_bad_id")

        echo ""
        log_info "--- Results for ${BUILD_TYPE_MAP[$type_code]} ($type_code) ---"
        log_info "Last known good build: $last_good_url"
        log_info "${RED}First known bad build: $first_bad_url${END}"

        print_commit_ranges_for_build "$first_bad_id"

        # Generate commit bisection XML for the next stage
        print_commit_bisection_instruction "$type_code" "$last_good_id" "$first_bad_id"
    done
}

function exit_if_dry_run() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Dry run completed. Bisection XML file created at: $BISECT_CONFIG_FILE"
        exit $EXIT_SUCCESS
    fi
}

# --- Main Script Logic ---
function main() {
    trap cleanup EXIT

    check_commands_available "xmlstarlet" "unzip" || fail_error "xmlstarlet and unzip are required. Please install them."

    parse_args "$@"

    if [[ -n "$INPUT_CONFIG_FILE" ]]; then
        log_info "Resuming bisection from $INPUT_CONFIG_FILE"
        BISECT_CONFIG_FILE="$INPUT_CONFIG_FILE"
        xml_util::load "$BISECT_CONFIG_FILE" || fail_error "Failed to load XML file: $BISECT_CONFIG_FILE"
    else
        validate_args
        log_info "Starting new bisection..."
        init_bisect_file
        exit_if_dry_run
    fi

    load_state_from_xml

    determine_default_device_type

    if [[ "$BISECT_STATUS" == "new" ]]; then
        log_info "--- New bisection: Validating initial builds to find breaking types ---"
        validate_initial_builds
        log_info "--- Initial validation complete ---"
        xml_util::update_xml_node "/bisect/state/@status" "in_progress"
    elif [[ "$BISECT_STATUS" == "complete" ]]; then
        log_info "Bisection is already complete according to state file. Showing final results."
        bisect_all_breaking_builds
        exit $EXIT_SUCCESS
    else
         log_info "--- Resuming bisection. Skipping initial validation. ---"
    fi

    bisect_all_breaking_builds
}

# Execute main
main "$@"