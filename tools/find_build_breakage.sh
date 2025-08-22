#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

#
# A build-level bisect testing tool to find breaking changes in Android builds.
#

# --- Configuration Constants ---
readonly DEFAULT_BISECT_BUILDS_FILENAME="bisect_builds.xml"
readonly DEFAULT_OUTPUT_DIR="out/$(date +%Y%m%d_%H%M%S)"
readonly DEFAULT_TEST_RETRY=3
readonly DEFAULT_SETUP_RETRY=3
readonly DEFAULT_DOWNLOAD_RETRY=3
readonly -A BUILD_TYPE_MAP=(
    ["pb"]="PLATFORM_BUILD"
    ["kb"]="KERNEL_BUILD"
    ["vkb"]="VENDOR_KERNEL_BUILD"
    ["tb"]="TEST_SUITE_BUILD"
)

# --- Global Variables ---
ACLOUD_OUTPUT_FILE="/tmp/acloud_output.tmp"
BUILD_TYPE=""
DEVICE_TYPE=""
PLATFORM_BUILD=""
KERNEL_BUILD=""
VENDOR_KERNEL_BUILD=""
SERIAL_NUMBER=""
TEST_NAME=()
TEST_DIR=""
TEST_SUITE_BUILD=""
CACHE_DIR=""
TEST_RETRY=$DEFAULT_TEST_RETRY
SETUP_RETRY=$DEFAULT_SETUP_RETRY
OUTPUT_DIR=""
INPUT_FILE=""
BISECT_FILE=""
SKIP_BUILD=false
TEMP_FILES=("$ACLOUD_OUTPUT_FILE")
TEMP_DIRS=()
CURRENT_INPUT_SERIAL=""
CURRENT_FASTBOOT_SERIAL=""
CURRENT_ADB_SERIAL=""
CURRENT_DEVICE_SERIAL=""
CURRENT_MODE_TYPE=""
CURRENT_DEVICE_TYPE=""

# Bisect state variables
GOOD_INDEX=-1
BAD_INDEX=-1
BISECT_STATUS=""
BUILDS_TO_TEST=()
BISECT_BRANCH=""
BISECT_TARGET=""
BISECT_FILENAME=""

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

# --- Scripts ---
readonly LAUNCH_CVD_SCRIPT="${SCRIPT_DIR}/launch_cvd.sh"
readonly FLASH_DEVICE_SCRIPT="${SCRIPT_DIR}/flash_device.sh"
readonly RUN_TEST_SCRIPT="${SCRIPT_DIR}/run_test_only.sh"
readonly QUERY_BUILD_SCRIPT="${SCRIPT_DIR}/query_build.sh"
readonly FETCH_ARTIFACT_SCRIPT="${SCRIPT_DIR}/fetch_artifact.sh"

# --- Functions ---
function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "A tool to perform build-level bisection to find the first failing Android build."
    echo ""
    echo "To start a new bisection, you must specify a build range for one, and only one, of the build types."
    echo "The build argument with a range defines the target for bisection."
    echo ""
    echo "Modes:"
    echo "  New Bisection: Provide a build range via -pb, -kb, -vkb, or -td, along with -t."
    echo "  Resume Bisection: Provide -i to resume a previously started bisection."
    echo ""
    echo "Options:"
    echo "  -pb,  --platform-build <url|path>"
    echo "                                   A platform build. To bisect, use a range format."
    echo "                                   Format: ab://<branch>/<target>/<id1>-<id2> OR ab://.../<id1,id2,...>"
    echo "  -kb,  --kernel-build <url|path>"
    echo "                                   A kernel build. To bisect, use a range format."
    echo "  -vkb, --vendor-kernel-build <url|path>"
    echo "                                   A vendor kernel build. To bisect, use a range format."
    echo "  -s,   --serial-number <serial>   The physical device serial. If omitted, uses a Cuttlefish virtual device."
    echo "  -t,   --test <name>              [Required] The test name(s) to run. Can be repeated. (e.g., 'CtsMyModuleTest')"
    echo "  -td, --test-dir, -tb, --test-suite-build <url|path>"
    echo "                                   [Required] Path to test artifacts or an ab:// URL to download or bisect them."
    echo "                                   Bisection URL Format: ab://<branch>/<target>/<id-range>/<filename.zip>"
    echo "                                   URL Format: ab://<branch>/<target>/<id>/<filename.zip>"
    echo "  -tr,  --test-retry <count>       Retry count for a failed test. Default: ${DEFAULT_TEST_RETRY}."
    echo "  -sr,  --setup-retry <count>      Retry count for failed device setup. Default: ${DEFAULT_SETUP_RETRY}."
    echo "  --skip-build                     [Optional] If set, pass '--skip-build' to underlying flash/launch scripts."
    echo "  -cd,  --cache-dir <path>         [Optional] A persistent directory for downloaded test suites."
    echo "  -od,  --output-dir <path>        Path of Directory to store the bisection state XML file. Default: ${DEFAULT_OUTPUT_DIR}/${DEFAULT_BISECT_FILE}."
    echo "  -o,   --output-file <path>       Path to store the bisection state XML file. Default: ${DEFAULT_BISECT_FILE}."
    echo "  -i,   --input-file <path>        Resume bisection from the given state XML file."
    echo "  -h,   --help                     Display this help message."
    echo ""
    echo "Examples:"
    echo "  # Start a new bisection for a platform build regression on a Cuttlefish device"
    echo "  $0 -pb ab://git_main/oriole-userdebug/120000-130000 \\"
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

    while test $# -gt 0; do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            -i|--input-file)
                shift
                INPUT_FILE="$1"
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
            -kb|--kernel-build)
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
                TEST_DIR="$1"
                if [[ "$TEST_DIR" == ab://* ]]; then
                    TEST_SUITE_BUILD="$TEST_DIR"
                fi
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
            -cd|--cache-dir)
                shift
                CACHE_DIR="$1"
                shift
                ;;
            *)
                log_error "Unsupported flag: $1"
                print_help
                exit 1
                ;;
        esac
    done

    if [[ "$has_input_file" == true && ! -f "$INPUT_FILE" ]]; then
        fail_error "Input file not found: $INPUT_FILE"
    fi

    if "$has_input_file" && "$has_new_bisect_args"; then
        fail_error "Cannot specify new bisection options (-pb, -kb, etc.) when resuming with -i."
    fi

    if ! "$has_input_file"; then
        if [[ -z "$TEST_DIR" || ${#TEST_NAME[@]} -eq 0 ]]; then
             fail_error "For a new bisection, both --test (-t) and --test-dir (-td) must be specified."
        fi
    fi
}

function parse_build_string() {
    local build_str="$1"
    local -n branch_ref="$2"
    local -n target_ref="$3"
    local -n ids_ref="$4"
    local -n type_ref="$5" # Will be 'range', 'list', 'single', or 'local'
    local -n filename_ref="$6"

    if [[ "$build_str" != ab://* ]]; then
        if [[ -d "$build_str" ]]; then
            type_ref="local"
            ids_ref=("$build_str")
            return 0
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
    return 0
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
    if [[ -n "$CACHE_DIR" ]]; then
        base_dir=$(realpath "$CACHE_DIR")
        log_info "Using persistent cache directory: $base_dir"
    else
        base_dir="/tmp/bisect_builds"
        log_info "Using temporary directory: $base_dir"
    fi

    if [[ "$build_id" == "latest" ]]; then
        local staging_dir="${base_dir}/staging_$(date +%s%N)"
        TEMP_DIRS+=("$staging_dir")
        mkdir -p "$staging_dir" || fail_error "Could not create staging directory: ${staging_dir}"

        log_info "Build ID is 'latest', downloading to staging area to resolve version..."

        pushd "$staging_dir" >/dev/null || fail_error "pushd failed: Could not enter staging directory."
        local download_success=false
        for i in $(seq 1 "$DEFAULT_DOWNLOAD_RETRY"); do
            "$FETCH_ARTIFACT_SCRIPT" "$test_suite_url"
            if [[ $? -eq 0 && -f "$filename" ]]; then
                download_success=true
                break
            fi
            log_warn "Download failed (Attempt ${i}/${DEFAULT_DOWNLOAD_RETRY}). Retrying..."
            sleep 10
        done
        popd >/dev/null || fail_error "popd failed: Could not return from staging directory."

        if ! "$download_success"; then
            fail_error "Failed to download 'latest' test suite."
        fi

        local zip_file_path="${staging_dir}/${filename}"
        log_info "unzipping file: ${zip_file_path}..."
        unzip -q "$zip_file_path" -d "$staging_dir" || fail_error "Failed to unzip staging file."

        local unzipped_root_dir
        unzipped_root_dir=$(find "$staging_dir" -mindepth 1 -maxdepth 1 -type d)

        local version_file="${unzipped_root_dir}/tools/version.txt"
        if [[ ! -f "$version_file" ]]; then
            fail_error "Cannot resolve 'latest' build ID: 'tools/version.txt' not found."
        fi

        local resolved_build_id
        resolved_build_id=$(<"$version_file")
        if ! [[ "$resolved_build_id" =~ ^[0-9]+$ ]]; then
            fail_error "Invalid build ID found in version.txt: '$resolved_build_id'"
        fi
        log_info "Resolved 'latest' build ID to: $resolved_build_id"

        local final_suite_path="${base_dir}/${branch}/${target}/${resolved_build_id}"
        [[ -d "$final_suite_path" ]] && rm -rf "$final_suite_path"
        mkdir -p "$final_suite_path"

        mv "$unzipped_root_dir" "$final_suite_path/" || fail_error "Failed to move test suite to final location."
        TEST_DIR="${final_suite_path}/$(basename "$unzipped_root_dir")"

    else # This branch handles numeric build IDs
        local suite_path="${base_dir}/${branch}/${target}/${build_id}"

        if [[ -z "$CACHE_DIR" ]]; then
            TEMP_DIRS+=("$suite_path")
        fi
        [[ -d "$suite_path" ]] && rm -rf "$suite_path"
        mkdir -p "$suite_path" || fail_error "Could not create directory: ${suite_path}"

        pushd "$suite_path" >/dev/null || fail_error "pushd failed: Could not enter suite directory."
        local download_success=false
        for i in $(seq 1 "$DEFAULT_DOWNLOAD_RETRY"); do
            "$FETCH_ARTIFACT_SCRIPT" "$test_suite_url"
            if [[ $? -eq 0 && -f "$filename" ]]; then
                download_success=true
                break
            fi
            log_warn "Download failed (Attempt ${i}/${DEFAULT_DOWNLOAD_RETRY}). Retrying..."
            sleep 10
        done
        popd >/dev/null || fail_error "popd failed: Could not return from suite directory."

        if ! "$download_success"; then
            fail_error "Failed to download test suite '${filename}'."
        fi

        log_info "unzipping file: ${filename}..."
        unzip -q "${suite_path}/${filename}" -d "${suite_path}" || fail_error "Failed to unzip file."
        rm -f "${suite_path}/${filename}"

        local unzipped_root_dir
        unzipped_root_dir=$(find "$suite_path" -mindepth 1 -maxdepth 1 -type d)
        TEST_DIR="$unzipped_root_dir"
    fi

    if [[ -z "$TEST_DIR" || ! -d "$TEST_DIR" ]]; then
        fail_error "Test suite directory could not be prepared correctly."
    fi

    TEST_DIR=$(realpath "$TEST_DIR")
    log_info "Test suite is ready at: ${TEST_DIR}"
}

function validate_args() {
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
    fi
    OUTPUT_DIR=$(realpath "$OUTPUT_DIR")
    BISECT_FILE="${OUTPUT_DIR}/${DEFAULT_BISECT_BUILDS_FILENAME}"

    if [[ -n "$INPUT_FILE" ]]; then
        return 0
    fi

    # --- New Bisection Validations ---
    local bisect_arg_found=false
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

        if [[ "$id_type" == "range" || "$id_type" == "list" ]]; then
            if "$bisect_arg_found"; then
                fail_error "Only one build argument may contain a bisection range."
            fi
            bisect_arg_found=true
            BUILD_TYPE="$type_code"
            BISECT_BRANCH="$branch"
            BISECT_TARGET="$target"
            BISECT_FILENAME="$filename"

            if [[ "$id_type" == "range" ]]; then
                get_build_ids "${ids[0]}" "${ids[1]}"
            else # list
                BUILDS_TO_TEST=("${ids[@]}")
            fi

            if (( ${#BUILDS_TO_TEST[@]} < 2 )); then
                 fail_error "Bisection requires at least two builds to test. Found ${#BUILDS_TO_TEST[@]}."
            fi
        fi
    done

    if ! "$bisect_arg_found"; then
        fail_error "New bisection requires one build argument to have a range (e.g., 1-2) or list (e.g., 1,2,3)."
    fi

    local fixed_builds_are_all_remote=true
    # Validate that other fixed builds are valid single builds or local paths.
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        # Skip the one we are bisecting
        if [[ "$type_code" == "$BUILD_TYPE" ]]; then
            continue
        fi

        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local build_value="${!var_name}"
        if [[ -n "$build_value" && "$build_value" != ab://* ]]; then
            fixed_builds_are_all_remote=false
        fi
    done

    # Warn if --skip-build is used pointlessly.
    if "$SKIP_BUILD" && "$fixed_builds_are_all_remote"; then
        log_warn "--skip-build is specified, but all provided builds are remote 'ab://' URLs. No local building would occur anyway."
    fi

    if [[ "$BUILD_TYPE" == "tb" ]]; then
        if [[ -z "$PLATFORM_BUILD" && -z "$KERNEL_BUILD" && -z "$VENDOR_KERNEL_BUILD" ]]; then
            fail_error "Test suite bisection requires a fixed device build (e.g., -pb, -kb) for the one-time setup."
        fi
        if [[ -z "$BISECT_FILENAME" ]]; then
            fail_error "Test suite bisection URL must include the filename (e.g., .../range/android-cts.zip)."
        fi
    fi

    # Handle single test suite URL (non-bisection case)
    if [[ "$BUILD_TYPE" != "tb" && -n "$TEST_SUITE_BUILD" ]]; then
        handle_test_suite_url "$TEST_SUITE_BUILD"
    fi
}

function fail_error() {
    local message="$1"
    local exit_code="${2:-1}"
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
    local start_id="$1"
    local end_id="$2"
    log_info "Fetching all build IDs from $start_id to $end_id..."

    if ! "$QUERY_BUILD_SCRIPT" -br "${BISECT_BRANCH}" -bt "${BISECT_TARGET}" -sbid "${start_id}" -ebid "${end_id}"; then
        fail_error "Error running query_build.sh. branch: ${BISECT_BRANCH}, build_target: ${BISECT_TARGET}"
    fi

    local queryfile="/tmp/build_query_output.csv"
    local -a unsorted_build_ids_array
    mapfile -t unsorted_build_ids_array < <(extract_build_ids_from_file "$queryfile")
    mapfile -t BUILDS_TO_TEST < <(printf "%s\n" "${unsorted_build_ids_array[@]}" | sort -n)

    if (( ${#BUILDS_TO_TEST[@]} == 0 )); then
        fail_error "Could not find any builds between $start_id and $end_id for target $BISECT_TARGET on branch $BISECT_BRANCH."
    fi
    log_info "Found ${#BUILDS_TO_TEST[@]} builds to test."
}

function xml::add_node() {
    local -n cmd_array_ref=$1
    local parent_xpath=$2
    local element_name=$3
    cmd_array_ref+=(-s "$parent_xpath" -t elem -n "$element_name")
}

function xml::add_attribute() {
    local -n cmd_array_ref=$1
    local parent_xpath=$2
    local attr_name=$3
    local attr_value=$4
    cmd_array_ref+=(-i "$parent_xpath" -t attr -n "$attr_name" -v "$attr_value")
}

function xml::add_element() {
    local -n cmd_array_ref=$1
    local parent_xpath=$2
    local element_name=$3
    local element_value=$4
    cmd_array_ref+=(-s "$parent_xpath" -t elem -n "$element_name" -v "$element_value")
}

function init_bisect_file() {
    log_info "Initializing new bisection state file: $BISECT_FILE"

    local good_build_index=0
    local bad_build_index=$(( ${#BUILDS_TO_TEST[@]} - 1 ))

    # Create base XML structure
    echo '<?xml version="1.0" encoding="UTF-8"?><bisect/>' > "$BISECT_FILE"
    local -a xml_edit_cmd=("xmlstarlet" "ed" "-L")

    # State node
    xml::add_node       xml_edit_cmd "/bisect" "state"
    xml::add_attribute  xml_edit_cmd "/bisect/state" "build_type"  "$BUILD_TYPE"
    xml::add_attribute  xml_edit_cmd "/bisect/state" "good_index"  "$good_build_index"
    xml::add_attribute  xml_edit_cmd "/bisect/state" "bad_index"   "$bad_build_index"
    xml::add_attribute  xml_edit_cmd "/bisect/state" "status"      "new"

    # Parameters node
    xml::add_node       xml_edit_cmd "/bisect" "parameters"
    xml::add_attribute  xml_edit_cmd "/bisect/parameters" "test_dir"      "$TEST_DIR"
    xml::add_attribute  xml_edit_cmd "/bisect/parameters" "output_dir"    "$OUTPUT_DIR"
    xml::add_attribute  xml_edit_cmd "/bisect/parameters" "test_retry"    "$TEST_RETRY"
    xml::add_attribute  xml_edit_cmd "/bisect/parameters" "setup_retry"   "$SETUP_RETRY"
    xml::add_attribute  xml_edit_cmd "/bisect/parameters" "serial_number" "$SERIAL_NUMBER"
    xml::add_attribute  xml_edit_cmd "/bisect/parameters" "skip_build"    "$SKIP_BUILD"
    for test in "${TEST_NAME[@]}"; do
        xml::add_element xml_edit_cmd "/bisect/parameters" "test" "$test"
    done

    # Bisected build list
    local build_node_name
    case "$BUILD_TYPE" in
        pb) build_node_name="platform_builds" ;;
        kb) build_node_name="kernel_builds" ;;
        vkb) build_node_name="vendor_kernel_builds" ;;
        tb) build_node_name="test_suite_builds" ;;
    esac
    xml::add_node       xml_edit_cmd "/bisect" "$build_node_name"
    xml::add_attribute  xml_edit_cmd "/bisect/$build_node_name" "branch" "$BISECT_BRANCH"
    xml::add_attribute  xml_edit_cmd "/bisect/$build_node_name" "target" "$BISECT_TARGET"
    if [[ "$BUILD_TYPE" == "tb" ]]; then
        xml::add_attribute xml_edit_cmd "/bisect/$build_node_name" "filename" "$BISECT_FILENAME"
    fi
    for build_id in "${BUILDS_TO_TEST[@]}"; do
        xml::add_element xml_edit_cmd "/bisect/$build_node_name" "build" "$build_id"
    done

    # Fixed builds
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        if [[ "$type_code" != "$BUILD_TYPE" ]]; then
            local var_name="${BUILD_TYPE_MAP[$type_code]}"
            local build_value="${!var_name}"
            if [[ -n "$build_value" ]]; then
                local tag_name="${var_name,,}"
                xml::add_element xml_edit_cmd "/bisect" "$tag_name" "$build_value"
            fi
        fi
    done

    # Execute the command
    "${xml_edit_cmd[@]}" "$BISECT_FILE"
}

function xml::read_value() {
    local xpath=$1
    xmlstarlet sel -t -v "$xpath" "$BISECT_FILE" 2>/dev/null
}

function xml::read_values_to_array() {
    local xpath=$1
    local -n array_ref=$2
    mapfile -t array_ref < <(xmlstarlet sel -t -v "$xpath" -n "$BISECT_FILE" 2>/dev/null)
}

function load_state_from_xml() {
    log_info "Loading state from $BISECT_FILE..."
    # State
    BUILD_TYPE=$(xml::read_value "/bisect/state/@build_type")
    GOOD_INDEX=$(xml::read_value "/bisect/state/@good_index")
    BAD_INDEX=$(xml::read_value "/bisect/state/@bad_index")
    BISECT_STATUS=$(xml::read_value "/bisect/state/@status")

    # Parameters
    TEST_DIR=$(xml::read_value "/bisect/parameters/@test_dir")
    OUTPUT_DIR=$(xml::read_value "/bisect/parameters/@output_dir")
    TEST_RETRY=$(xml::read_value "/bisect/parameters/@test_retry")
    SETUP_RETRY=$(xml::read_value "/bisect/parameters/@setup_retry")
    SERIAL_NUMBER=$(xml::read_value "/bisect/parameters/@serial_number")
    SKIP_BUILD=$(xml::read_value "/bisect/parameters/@skip_build")
    xml::read_values_to_array "/bisect/parameters/test" TEST_NAME

    # Bisected Builds
    local bisect_node_name
    case "$BUILD_TYPE" in
        pb) bisect_node_name="platform_builds" ;;
        kb) bisect_node_name="kernel_builds" ;;
        vkb) bisect_node_name="vendor_kernel_builds" ;;
        tb) bisect_node_name="test_suite_builds" ;;
    esac
    BISECT_BRANCH=$(xml::read_value "/bisect/$bisect_node_name/@branch")
    BISECT_TARGET=$(xml::read_value "/bisect/$bisect_node_name/@target")
    if [[ "$BUILD_TYPE" == "tb" ]]; then
        BISECT_FILENAME=$(xml::read_value "/bisect/$bisect_node_name/@filename")
    fi
    xml::read_values_to_array "/bisect/$bisect_node_name/build" BUILDS_TO_TEST

    # Fixed Builds
    PLATFORM_BUILD=$(xml::read_value "/bisect/platform_build")
    KERNEL_BUILD=$(xml::read_value "/bisect/kernel_build")
    VENDOR_KERNEL_BUILD=$(xml::read_value "/bisect/vendor_kernel_build")
    TEST_SUITE_BUILD=$(xml::read_value "/bisect/test_suite_build")

    log_info "State loaded successfully. Good: ${BUILDS_TO_TEST[$GOOD_INDEX]}, Bad: ${BUILDS_TO_TEST[$BAD_INDEX]}. Status: $BISECT_STATUS"

    # Restore missing test suite directory if necessary.
    # This is a self-correcting side effect to ensure the state is usable.
    if [[ -n "$TEST_SUITE_BUILD" && ! -d "$TEST_DIR" ]]; then
        log_info "Restoring missing test suite from URL... please wait."
        log_info "URL: $TEST_SUITE_BUILD"
        handle_test_suite_url "$TEST_SUITE_BUILD"
        xml::update_xml_node "/bisect/parameters/@test_dir" "$TEST_DIR"
    fi
}

function xml::update_xml_node() {
    local xpath_expr="$1"
    local value="$2"
    log_info "Updating XML state in $BISECT_FILE: $xpath_expr -> $value"
    xmlstarlet ed -L -u "$xpath_expr" -v "$value" "$BISECT_FILE"
}

function perform_device_setup() {
    local pb="$1" kb="$2" vkb="$3"

    local -a setup_cmd_array=()
    if [[ "$DEVICE_TYPE" == "PHYSICAL" ]]; then
        setup_cmd_array=("$FLASH_DEVICE_SCRIPT" "-s" "$SERIAL_NUMBER")
        [[ -n "$pb" ]] && setup_cmd_array+=("-pb" "$pb")
        [[ -n "$kb" ]] && setup_cmd_array+=("-kb" "$kb")
        [[ -n "$vkb" ]] && setup_cmd_array+=("-vkb" "$vkb")
    elif [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        setup_cmd_array=("$LAUNCH_CVD_SCRIPT")
        [[ -n "$pb" ]] && setup_cmd_array+=("-pb" "$pb")
        [[ -n "$kb" ]] && setup_cmd_array+=("-kb" "$kb")
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
        if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
            unbuffer "${setup_cmd_array[@]}" | tee "$ACLOUD_OUTPUT_FILE"
            setup_status=${PIPESTATUS[0]}
        else
            "${setup_cmd_array[@]}"
            setup_status=$?
        fi

        if (( setup_status == 0 )); then
            setup_success=true
            break
        fi
        log_warn "Setup failed (Attempt $i/$SETUP_RETRY). Retrying..."
        sleep 10
    done

    if ! "$setup_success"; then
        fail_error "Device setup failed after $SETUP_RETRY attempts."
    fi

    log_info "Device setup successful."
}

function run_tests_on_device() {
    local input_serial_to_use="$SERIAL_NUMBER"
    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        input_serial_to_use=$(grep -oP "ANDROID_SERIAL=\K[\.0-9:]+" "$ACLOUD_OUTPUT_FILE")
    fi

    device::set_current "$input_serial_to_use" || return 1
    if [[ "$DEVICE_TYPE" == "VIRTUAL" ]]; then
        adb -s "$CURRENT_ADB_SERIAL" wait-for-device
        while ! adb -s "$CURRENT_ADB_SERIAL" shell pm path com.android.settings > /dev/null 2>&1; do
            log_info "Waiting for package manager on $CURRENT_ADB_SERIAL..."
            sleep 5
        done
    else
        unlock_screen "$CURRENT_ADB_SERIAL"
        skip_setup_wizard "$CURRENT_ADB_SERIAL"
    fi

    local -a test_cmd=("$RUN_TEST_SCRIPT" "-td" "$TEST_DIR" "-tl" "$OUTPUT_DIR/test_logs")
    # [[ "$CURRENT_MODE_TYPE" == "FASTBOOT" ]] && test_cmd+=("-s" "$CURRENT_FASTBOOT_SERIAL")
    [[ "$CURRENT_MODE_TYPE" == "ADB" ]] && test_cmd+=("-s" "$CURRENT_ADB_SERIAL")
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
    return 1 # BAD
}

function setup_and_test_build() {
    local build_id_to_test="$1"
    local current_pb="$PLATFORM_BUILD"
    local current_kb="$KERNEL_BUILD"
    local current_vkb="$VENDOR_KERNEL_BUILD"

    case "$BUILD_TYPE" in
        pb) current_pb="ab://${BISECT_BRANCH}/${BISECT_TARGET}/${build_id_to_test}" ;;
        kb) current_kb="ab://${BISECT_BRANCH}/${BISECT_TARGET}/${build_id_to_test}" ;;
        vkb) current_vkb="ab://${BISECT_BRANCH}/${BISECT_TARGET}/${build_id_to_test}" ;;
    esac

    perform_device_setup "$current_pb" "$current_kb" "$current_vkb"
    run_tests_on_device
    return $?
}

function setup_and_run_test_suite() {
    local build_id_to_test="$1"

    log_info "Preparing test suite for build ID: $build_id_to_test"
    local suite_url_to_test="ab://${BISECT_BRANCH}/${BISECT_TARGET}/${build_id_to_test}/${BISECT_FILENAME}"

    handle_test_suite_url "$suite_url_to_test"

    xml::update_xml_node "/bisect/parameters/@test_dir" "$TEST_DIR"
    # When bisecting test suites, the "fixed" build URL is the one we are currently testing.
    xml::update_xml_node "/bisect/test_suite_build" "$suite_url_to_test"

    run_tests_on_device
    return $?
}

function perform_one_time_device_setup() {
    log_info "Performing one-time device setup for test suite bisection..."
    perform_device_setup "$PLATFORM_BUILD" "$KERNEL_BUILD" "$VENDOR_KERNEL_BUILD"
    log_info "One-time device setup complete."
}

function validate_initial_bounds() {
    log_info "--- Validating Good Build (${BUILDS_TO_TEST[0]}) ---"
    local test_status
    if [[ "$BUILD_TYPE" == "tb" ]]; then
        setup_and_run_test_suite "${BUILDS_TO_TEST[0]}"
        test_status=$?
    else
        setup_and_test_build "${BUILDS_TO_TEST[0]}"
        test_status=$?
    fi
    if (( test_status != 0 )); then
        fail_error "Validation failed: The first build in the range is FAILING the test."
    fi
    log_info "Good Build validation successful."

    local last_build_index=$(( ${#BUILDS_TO_TEST[@]} - 1 ))
    log_info "--- Validating Bad Build (${BUILDS_TO_TEST[$last_build_index]}) ---"
    if [[ "$BUILD_TYPE" == "tb" ]]; then
        setup_and_run_test_suite "${BUILDS_TO_TEST[$last_build_index]}"
        test_status=$?
    else
        setup_and_test_build "${BUILDS_TO_TEST[$last_build_index]}"
        test_status=$?
    fi
    if (( test_status == 0 )); then
        fail_error "Validation failed: The last build in the range is PASSING the test."
    fi
    log_info "Bounds validation successful."
}

function skip_setup_wizard() {
    local android_serial="$1"
    log_info "Device ${android_serial} is online. Waiting for package manager to be ready..."
    # Loop until the package manager is queryable, which is a good sign that the core system is up.
    while ! adb -s "${android_serial}" shell pm path com.android.settings > /dev/null 2>&1; do
        sleep 2
    done

    log_info "Core system is up. Disabling Setup Wizard..."
    # --- Commands to Disable Setup Wizard ---
    adb -s "${android_serial}" shell settings put global device_provisioned 1
    adb -s "${android_serial}" shell settings put secure user_setup_complete 1

    # --- Disable the wizard package itself as a fallback ---
    # Find the package name (it can vary)
    local SETUP_WIZARD_PKG
    SETUP_WIZARD_PKG=$(adb -s "${android_serial}" shell pm list packages | grep -i 'setupwizard' | head -n 1 | cut -d':' -f2)
    if [ -n "$SETUP_WIZARD_PKG" ]; then
        log_info "Found setup wizard package: $SETUP_WIZARD_PKG. Disabling..."
        adb -s "${android_serial}" shell pm disable-user --user 0 "$SETUP_WIZARD_PKG"
    else
        log_warn "Could not find setup wizard package automatically."
    fi

    log_info "Setup Wizard skipped. Device should now be at the home screen."
    echo "------------------------------------------------------------------"
}

function unlock_screen() {
    local android_serial="$1"
    local timeout_seconds=60

    log_info "Waiting for device to come online after reboot..."
    timeout $timeout_seconds adb -s "$android_serial" wait-for-device
    if (( $? == 124 )); then
        fail_error "Timeout reached, the device has no response."
    fi

    while [ "$(adb -s "${android_serial}" shell getprop sys.boot_completed | tr -d '\r')" != "1" ]; do
        sleep 5
    done

    log_info "The device boot complete..."

    local device_idle_status
    device_idle_status="$(adb -s "${android_serial}" shell dumpsys deviceidle)"

    local is_screen_on
    is_screen_on=$(echo "${device_idle_status}" | grep "mScreenOn" | cut -d'=' -f2)

    if [[ "${is_screen_on}" == "false" ]]; then
        log_info "Screen is off. Turning it on..."
        adb -s "$android_serial" shell input keyevent 26 || fail_error "Failed to turn on the screen."
        sleep 1
        # Refresh the status after the action.
        device_idle_status="$(adb -s "${android_serial}" shell dumpsys deviceidle)"
        is_screen_on=$(echo "${device_idle_status}" | grep "mScreenOn" | cut -d'=' -f2)
    fi

    # If the screen is now on, check if it's locked.
    if [[ "${is_screen_on}" == "true" ]]; then
        local is_screen_locked
        is_screen_locked=$(echo "${device_idle_status}" | grep "mScreenLocked" | cut -d'=' -f2)

        if [[ "${is_screen_locked}" == "true" ]]; then
            log_info "Screen is on and locked. Unlocking..."
            adb -s "$android_serial" shell input keyevent 82 || fail_error "Failed to unlock the screen."
            log_info "Screen unlocked successfully."
        else
            log_info "Screen is already on and unlocked."
        fi
    else
        fail_error "Can't turn on the screen. Please check the device."
    fi
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

function device::set_current() {
    local serial="$1"
    local found_device=false

    CURRENT_INPUT_SERIAL=""
    CURRENT_FASTBOOT_SERIAL=""
    CURRENT_ADB_SERIAL=""
    CURRENT_DEVICE_SERIAL=""
    CURRENT_MODE_TYPE=""
    CURRENT_DEVICE_TYPE=""

    if adb devices | grep -q "$serial"; then
        CURRENT_MODE_TYPE="ADB"
        CURRENT_ADB_SERIAL="$serial"
        CURRENT_DEVICE_SERIAL=$(adb -s "$CURRENT_ADB_SERIAL" shell getprop ro.serialno)
        found_device=true
    fi

    if fastboot devices | grep -q "$serial"; then
        CURRENT_MODE_TYPE="FASTBOOT"
        CURRENT_FASTBOOT_SERIAL="$serial"
        local serial_info
        serial_info=$(fastboot -s "$CURRENT_FASTBOOT_SERIAL" getvar serialno 2>&1)
        CURRENT_DEVICE_SERIAL=$(echo "$serial_info" | grep -Po "serialno: \K[A-Z0-9]+")
        found_device=true
    fi

    if [[ -x "$(command -v pontis)" && "$found_device" == false ]]; then
        local pontis_info
        pontis_info=$(pontis devices | grep "$serial")
        if [[ "$pontis_info" == *Fastboot* ]]; then
            CURRENT_MODE_TYPE="FASTBOOT"
            CURRENT_DEVICE_SERIAL="$serial"
            found_device=true
            log_info "Device $serial is connected through pontis in fastboot"
            device::find_fastboot_serial_number "$CURRENT_DEVICE_SERIAL"
        elif [[ "$pontis_info" == *ADB* ]]; then
            CURRENT_MODE_TYPE="ADB"
            CURRENT_DEVICE_SERIAL="$serial"
            found_device=true
            log_info "Device $serial is connected through pontis in adb"
            device::find_adb_serial_number "$CURRENT_DEVICE_SERIAL"
        fi
    fi

    if ! $found_device; then
        log_warn "Cannot find out the device ${serial}. Please check the device connection."
        return 1
    fi

    if [[ "$CURRENT_MODE_TYPE" == "ADB"  ]]; then
        local product
        product=$(adb -s "$CURRENT_ADB_SERIAL" shell getprop ro.product.board)
        if [[ "$product" == "cutf" ]]; then
            CURRENT_DEVICE_TYPE="VIRTUAL"
        else
            CURRENT_DEVICE_TYPE="PHYSICAL"
        fi
    else
        CURRENT_DEVICE_TYPE="PHYSICAL"
    fi

    [[ "$CURRENT_DEVICE_TYPE" == "$DEVICE_TYPE" ]] || log_error "The Current Device Type \
    ${CURRENT_DEVICE_TYPE} is inconsistent with Default Type ${DEVICE_TYPE}"

    CURRENT_INPUT_SERIAL="$serial"
    return 0
}

function device::find_fastboot_serial_number() {
    local device_serial="$1"
    local device_ids
    device_ids=$(fastboot devices | awk '{print $1}')
    while IFS= read -r device_id; do
        local _output
        _output=$(fastboot -s "$device_id" getvar serialno 2>&1)
        local target_device_serial
        target_device_serial=$(echo "$_output" | grep -Po "serialno: \K[A-Z0-9]+")
        if [[ "$target_device_serial" == "$device_serial" ]]; then
            CURRENT_FASTBOOT_SERIAL="$device_id"
            log_info "Device $device_serial shows up as $CURRENT_FASTBOOT_SERIAL in fastboot"
            return 0
        fi
    done <<< "$device_ids"
    fail_error "Can not find device in fastboot has device serial number $device_serial"
}

function device::find_adb_serial_number() {
    local device_serial="$1"
    log_info "Try to find device $device_serial serial id in adb devices"
    local _device_ids
    _device_ids=$(adb devices | awk '$2 == "device" {print $1}')
    local devices=()
    while IFS= read -r device_id; do
        devices+=("$device_id")
    done <<< "$_device_ids"

    for device_id in "${devices[@]}"; do
        local target_device_serial
        target_device_serial=$(adb -s "$device_id" shell getprop ro.serialno)
        if [[ "$target_device_serial" == "$device_serial" ]]; then
            CURRENT_ADB_SERIAL="$device_id"
            log_info "Device $device_serial shows up as $CURRENT_ADB_SERIAL in adb"
            return 0
        fi
    done
    fail_error "Can not find device in adb has device serial number $device_serial. \
    Check if the device is connected with adb authentication"
}

function bisect_builds() {
    log_info "========================================="
    log_info "Starting Bisection Loop"
    log_info "Device Type: $DEVICE_TYPE"
    log_info "Range: Index $GOOD_INDEX (Build ${BUILDS_TO_TEST[$GOOD_INDEX]}) to $BAD_INDEX (Build ${BUILDS_TO_TEST[$BAD_INDEX]})"
    log_info "========================================="

    while (( GOOD_INDEX + 1 < BAD_INDEX )); do
        local mid_index=$(( GOOD_INDEX + (BAD_INDEX - GOOD_INDEX) / 2 ))
        local mid_build_id=${BUILDS_TO_TEST[$mid_index]}

        log_info "--- Testing build at index: $mid_index (ID: $mid_build_id) ---"

        local test_status
        if [[ "$BUILD_TYPE" == "tb" ]]; then
            setup_and_run_test_suite "$mid_build_id"
            test_status=$?
        else
            setup_and_test_build "$mid_build_id"
            test_status=$?
        fi

        if (( test_status == 0 )); then
            log_info "RESULT: Build $mid_build_id is GOOD."
            GOOD_INDEX=$mid_index
            xml::update_xml_node "/bisect/state/@good_index" "$GOOD_INDEX"
        else
            log_info "RESULT: Build $mid_build_id is BAD."
            BAD_INDEX=$mid_index
            xml::update_xml_node "/bisect/state/@bad_index" "$BAD_INDEX"
        fi
        log_info "New Range: Index $GOOD_INDEX (Good) to $BAD_INDEX (Bad)"
    done

    log_info "========================================="
    log_info "Bisection Complete!"
    log_info "========================================="
    xml::update_xml_node "/bisect/state/@status" "complete"

    local first_bad_id=${BUILDS_TO_TEST[$BAD_INDEX]}
    local last_good_id=${BUILDS_TO_TEST[$GOOD_INDEX]}

    local first_bad_url="ab://${BISECT_BRANCH}/${BISECT_TARGET}/${first_bad_id}"
    local last_good_url="ab://${BISECT_BRANCH}/${BISECT_TARGET}/${last_good_id}"

    log_info "Last known good build: $last_good_url"
    log_info "${RED}First known bad build: $first_bad_url${END}"
}

# --- Main Script Logic ---
function main() {
    trap cleanup EXIT

    check_commands_available "xmlstarlet" "unzip" || fail_error "xmlstarlet and unzip are required. Please install them."

    parse_args "$@"

    if [[ -n "$INPUT_FILE" ]]; then
        log_info "Resuming bisection from $INPUT_FILE"
        BISECT_FILE="$INPUT_FILE"
    else
        validate_args
        log_info "Starting new bisection..."
        init_bisect_file
    fi

    load_state_from_xml

    determine_default_device_type

    if [[ "$BUILD_TYPE" == "tb" ]]; then
        perform_one_time_device_setup
    fi

    if [[ "$BISECT_STATUS" == "new" ]]; then
        log_info "--- New bisection: Validating initial good and bad build boundaries ---"
        validate_initial_bounds
        log_info "--- Initial boundaries validated successfully ---"
        xml::update_xml_node "/bisect/state/@status" "in_progress"
    elif [[ "$BISECT_STATUS" == "complete" ]]; then
        log_info "Bisection is already complete according to state file. Nothing to do."
        bisect_builds # Show the final result again
        exit 0
    else
         log_info "--- Resuming bisection. Skipping initial bounds validation. ---"
    fi

    bisect_builds
}

# Execute main
main "$@"