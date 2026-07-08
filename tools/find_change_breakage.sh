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
CLEAN_GIT=false
DRY_RUN=false
CURRENT_TEST_LOG_PREFIX=""
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
declare -A SYNC_MANIFEST_TARGETS # Stores ab:// URLs for --sync-manifest
declare -A ORIGINAL_MANIFESTS # Stores original manifest.xml basename before sync
declare -A GOOD_INDICES
declare -A BAD_INDICES
declare -A IS_BREAKING
declare -A GOOD_REVS
declare -A BAD_REVS
declare -A PROJECT_COUNT
declare -A CURRENT_SPLIT_STATES # Stores the currently checked-out split index for manifest_diff

# Holds the list of build type codes that were identified as breaking.
BISECT_BUILD_TYPES=()
IGNORE_PROJECTS=()
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
    echo "  For Auto Cross-Project Bisection (manifest_diff):"
    echo "    \$ANDROID_TREE_PATH:ab://<branch>/<target>/<good_build_id>-<bad_build_id>"
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
    echo "  --dry-run                        [Optional] Initialize the bisection XML file and exit without running tests."
    echo "  --sync-manifest <type>=<url>...  [Optional] Lock workspace to a manifest. Supports multiple (e.g. kb=ab://... pb=ab://...)"
    echo "  --ignore-projects <path>         [Optional] Ignore a project during manifest_diff. Can be repeated (e.g. --ignore-projects docs/)"
    echo "  --clean                          [Optional] Run 'git clean -fdx' before checking out commits to ensure a clean state.
  --non-interactive                [Optional] Disable interactive mode on build failures."
    echo "  --with-setup <script_path>       [Optional] Path to a custom script to run after checkout, before build."
    echo "  -od,  --output-dir <path>        Directory to store the state XML file. Default: ${DEFAULT_OUTPUT_DIR}/${DEFAULT_BISECT_CONFIG_FILENAME}."
    echo "  -i,   --input-config-file <path> Resume bisection from the given state XML file."
    echo "  -h,   --help                     Display this help message."
    echo ""
    echo "Environment Variables:"
    echo "  REPO_INIT_MANIFEST_URL           Override the default manifest URL used during workspace initialization."
    echo "                                   (Default: sso://android/platform/manifest or sso://android/kernel/manifest)"
    echo ""
    echo "Examples:"
    echo "  # Bisection Mode: Bisect a commit range in a specific project"
    echo "  $0 -pb ~/main/vendor/xts:c1d2e3f-a7b8c9d -t MyTest -td /path/to/android-cts"
    echo ""
    echo "  # Bisect one project while pinning another to a specific commit"
    echo "  $0 -pb ~/main/frameworks/base:a1b2c3d-e4f5a6b -kb ~/main/kernel/common:abc1234 -t MyTest -td /path/to/android-cts"
    echo ""
    echo "  # Auto Cross-Project Bisection (manifest_diff): Bisect across multiple projects between two remote builds"
    echo "  $0 \\"
    echo "    -pb ab://git_26Q1-release/aosp_cf_x86_64_phone-userdebug/15265174 \\"
    echo "    -kb ~/test_motions_a15-6.6:ab://aosp_kernel-common-android15-6.6-2026-01/kernel_virt_x86_64/15293967-15300724 \\"
    echo "    -td ab://partner-android16-m1-tests-dev/test_suites_x86_64-bp4a/15293638/android-cts.zip \\"
    echo "    -t \"CtsHardwareTestCases android.hardware.input.cts.tests.SonyDualSenseEdgeUsbTest#testAllMotions\""
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
            --ignore-projects)
                IGNORE_PROJECTS+=("$2")
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --clean)
                CLEAN_GIT=true
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
            --sync-manifest)
                shift
                local count=0
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    local raw_arg="$1"
                    if [[ "$raw_arg" != *"="* ]]; then
                        fail_error "Invalid format for --sync-manifest argument: '$raw_arg'. Must be <build_type>=<ab_url>"
                    fi
                    local build_type="${raw_arg%%=*}"
                    local ab_url="${raw_arg#*=}"
                    if [[ "$build_type" != "pb" && "$build_type" != "kb" && "$build_type" != "vkb" && "$build_type" != "sb" ]]; then
                        fail_error "Invalid build type '$build_type' for --sync-manifest. Must be pb, kb, vkb, or sb."
                    fi
                    SYNC_MANIFEST_TARGETS[$build_type]="$ab_url"
                    shift
                    count=$((count+1))
                done
                if (( count == 0 )); then
                    fail_error "--sync-manifest requires at least one argument in the format <build_type>=<ab_url>"
                fi
                has_new_bisect_args=true
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

    if "$has_input_file" && "$DRY_RUN"; then
        fail_error "Cannot specify --dry-run when resuming with -i."
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

function ensure_commit_exists_locally() {
    local r
    local project_path="$1"
    local commit="$2"

    if (cd "$project_path" && git cat-file -e "$commit" &>/dev/null); then
        return 0
    fi

    log_info "Commit $commit not found locally in $project_path. Attempting to fetch..."
    local remotes
    remotes=$(cd "$project_path" && git remote)
    local fetched=false
    for r in $remotes; do
        log_info "Fetching $commit from remote '$r'..."
        if (cd "$project_path" && git fetch "$r" "$commit" --quiet &>/dev/null); then
            fetched=true
            break
        fi
    done

    if ! $fetched; then
        fail_error "Failed to fetch commit $commit from any remote in $project_path."
    fi
}

function get_commits_in_range() {
    local project_path="$1"
    local start_commit="$2"
    local end_commit="$3"
    local -n result_array_ref="$4"

    log_info "Fetching all commits in project '$project_path' from $start_commit to $end_commit..."

    ensure_commit_exists_locally "$project_path" "$start_commit"
    ensure_commit_exists_locally "$project_path" "$end_commit"

    # Use rev-list to get all commits between start (exclusive) and end (inclusive)
    mapfile -t result_array_ref < <(cd "$project_path" && git rev-list --ancestry-path --reverse "$start_commit..$end_commit")

    if (( ${#result_array_ref[@]} == 0 )); then
        fail_error "Could not find any commits between ${start_commit} and ${end_commit} for project ${project_path}."
    fi
    log_info "Found ${#result_array_ref[@]} commits to test for ${project_path}."
}

function validate_input_flags() {
    local build_type
    OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
    fi
    OUTPUT_DIR=$(realpath "$OUTPUT_DIR")
    BISECT_CONFIG_FILE="${OUTPUT_DIR}/${DEFAULT_BISECT_CONFIG_FILENAME}"

    if [[ -n "$INPUT_CONFIG_FILE" ]]; then
        return 0
    fi

    for build_type in "${!SYNC_MANIFEST_TARGETS[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$build_type]}"
        if [[ -z "$var_name" || -z "${!var_name}" ]]; then
            fail_error "Found --sync-manifest $build_type but missing corresponding build flag (e.g., -$build_type)."
        fi
    done
}

function check_uncommitted_changes() {
    local type_code="$1"
    local tree_path="$2"
    local -n checked_trees_ref="$3"

    if [[ -z "${checked_trees_ref["$tree_path"]:-}" ]]; then
        log_info "[$type_code] Checking for uncommitted changes in tree: $tree_path ..."
        local dirty_projects
        dirty_projects=$(cd "$tree_path" && repo forall -c 'git diff-index --quiet HEAD || echo "$REPO_PROJECT"')
        if [[ -n "$dirty_projects" ]]; then
            local error_msg
            printf -v error_msg "[%s] Found uncommitted changes in the following projects under %s:\n%s\nPlease commit or stash them before running." \
                "$type_code" "$tree_path" "$dirty_projects"
            fail_error "$error_msg"
        fi
        checked_trees_ref["$tree_path"]="1"
    fi
}

function generate_ai_commit_report() {
    local type_code="$1"
    local report_prefix="$2" # e.g. "candidate_commits" or "culprit_commits"
    local repo_path="$3"
    local good_rev="$4"
    local bad_rev="$5"
    local project_name="$6"

    local safe_proj_name="${project_name//\//_}"
    if [[ -z "$safe_proj_name" || "$safe_proj_name" == "none" ]]; then
        safe_proj_name="$type_code"
    fi
    local report_out="${OUTPUT_DIR}/${report_prefix}_${type_code}_${safe_proj_name}.json"
    local script_path="${SCRIPT_DIR}/lib/generate_commit_report.py"

    if [[ -f "$script_path" && -n "$good_rev" && -n "$bad_rev" && -d "$repo_path" ]]; then
        log_info "[$type_code] Generating AI metadata report ($report_prefix) for ${project_name:-$type_code}..."
        python3 "$script_path" \
            --repo_path "$repo_path" \
            --good_rev "$good_rev" \
            --bad_rev "$bad_rev" \
            --project_name "${project_name:-$type_code}" \
            --out_file "$report_out"
    fi
}

function verify_git_commit_ranges() {
    local commit
    local i
    local type_code="$1"
    local id_type="$2"
    local tree_path="$3"
    local project="$4"
    local -n commits_ref="$5"
    local -n has_bisection_target_ref="$6"

    log_info "Validating git argument for '$type_code' (type: $id_type)..."

    local full_project_path="${tree_path}/${project}"
    if [[ ! -d "$full_project_path/.git" ]]; then
        fail_error "[$type_code] Project path is not a git repository: $full_project_path"
    fi

    # Verify project exists in `repo list`
    local repo_list_output
    repo_list_output=$(cd "$tree_path" && repo list)
    if ! echo "$repo_list_output" | grep -q "^${project} "; then
         fail_error "[$type_code] Project path '${project}' not found in 'repo list' for tree '${tree_path}'."
    fi

    # Verify commits and fetch if missing
    for commit in "${commits_ref[@]}"; do
        ensure_commit_exists_locally "$full_project_path" "$commit"
    done

    # --- Type-specific validation ---
    if [[ "$id_type" == "range" || "$id_type" == "list" ]]; then
        has_bisection_target_ref=true
        local -a commits_to_test=()
        if [[ "$id_type" == "range" ]]; then
            local start_commit="${commits_ref[0]}"
            local end_commit="${commits_ref[1]}"
            # 4. Check commit order for range
            if ! (cd "$full_project_path" && git merge-base --is-ancestor "$start_commit" "$end_commit"); then
                fail_error "[$type_code] Start commit $start_commit is not an ancestor of end commit $end_commit."
            fi
            get_commits_in_range "$full_project_path" "$start_commit" "$end_commit" commits_to_test
        else # list
            # 5. Check commit order for list
            local sorted_commits
            sorted_commits=($(cd "$full_project_path" && git rev-list --topo-order --no-walk "${commits_ref[@]}"))
            for i in "${!commits_ref[@]}"; do
                if [[ "${commits_ref[$i]}" != "${sorted_commits[$i]}" ]]; then
                    fail_error "[$type_code] Commit list is not in ascending chronological order. Expected order starts with: ${sorted_commits[*]}"
                fi
            done
            commits_to_test=("${commits_ref[@]}")
        fi

        if (( ${#commits_to_test[@]} < 2 )); then
             fail_error "Bisection for '$type_code' requires at least two commits. Found ${#commits_to_test[@]}."
        fi
        COMMITS_TO_TEST_MAP[$type_code]="${commits_to_test[*]}"

        if [[ "$id_type" == "range" ]]; then
            generate_ai_commit_report "$type_code" "candidate_commits" "$full_project_path" "${commits_ref[0]}" "${commits_ref[1]}" "$project"
        fi
    else # fixed_commit
        COMMITS_TO_TEST_MAP[$type_code]="${commits_ref[0]}" # Store the single commit
    fi

    save_initial_git_state "$type_code"
}

function apply_custom_manifest() {
    local type_code="$1"
    local is_resume="$2"
    local tree_path="${TREE_PATHS[$type_code]}"
    local ab_url="${SYNC_MANIFEST_TARGETS[$type_code]}"

    if [[ -z "$tree_path" || -z "$ab_url" ]]; then
        return 0
    fi

    log_info "[$type_code] Applying custom manifest: $ab_url"
    local cache_file=""
    common_lib::fetch_manifest "$type_code" "$ab_url" cache_file || fail_error "[$type_code] Manifest fetch failed"
    local manifest_filename=$(basename "$cache_file")

    if [[ "$is_resume" != "true" ]]; then
        local original_manifest
        original_manifest=$(common_lib::get_active_manifest_name "$tree_path")
        ORIGINAL_MANIFESTS[$type_code]="$original_manifest"
    fi

    cp "$cache_file" "${tree_path}/.repo/manifests/" || fail_error "Failed to copy manifest to ${tree_path}/.repo/manifests/"
    common_lib::sync_tree_to_manifest "$tree_path" "$manifest_filename" "$type_code" || fail_error "[$type_code] repo sync failed"
}

function restore_workspace_state() {
    local type_code
    log_info "Restoring workspace state..."
    for type_code in "${!SYNC_MANIFEST_TARGETS[@]}"; do
        apply_custom_manifest "$type_code" "true"
    done
}

function validate_and_process_args() {
    local type_code
    local existing_type
    local proj_path
    local i
    log_info "Starting argument validation and processing..."
    validate_input_flags
    common_lib::check_disk_space 90 "$OUTPUT_DIR" "/tmp" || log_warn "Insufficient disk space detected. Proceeding anyway, but you may encounter issues."

    if [[ -n "$INPUT_CONFIG_FILE" ]]; then
        return 0
    fi

    local current_device_type="VIRTUAL"
    if [[ -n "$SERIAL_NUMBER" ]]; then
        current_device_type="PHYSICAL"
    fi

    # --- New Run Validations ---
    log_info "Validating inputs for a new bisection run..."
    local has_bisection_target=false
    local script_root_dir
    script_root_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    local -A checked_trees=()

    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        local var_name="${BUILD_TYPE_MAP[$type_code]}"
        local build_value="${!var_name}"
        if [[ -z "$build_value" ]]; then
            continue
        fi

        log_info "Processing configuration for component: ${type_code}"

        local tree_path project
        local -a target_ids=()
        local id_type=""
        common_lib::parse_change_string "$build_value" tree_path project target_ids id_type || fail_error "Failed to parse change string: $build_value"

        if [[ "$id_type" == "manifest_diff" ]]; then
            local diff_branch="${target_ids[0]}"
            local diff_target="${target_ids[1]}"
            local good_id="${target_ids[2]}"
            local bad_id="${target_ids[3]}"

            # Enforce ONE manifest_diff per run
            for existing_type in "${!ID_TYPES[@]}"; do
                if [[ "${ID_TYPES[$existing_type]}" == "manifest_diff" && "$existing_type" != "$type_code" ]]; then
                    fail_error "Only one manifest_diff parameter is allowed per run. Found another on $existing_type."
                fi
            done

            local explicit_sync="${SYNC_MANIFEST_TARGETS[$type_code]}"
            if [[ -z "$explicit_sync" ]]; then
                log_info "[$type_code] Auto-fallback: Locking workspace to Bad Build ($bad_id) for manifest_diff."
                SYNC_MANIFEST_TARGETS[$type_code]="ab://${diff_branch}/${diff_target}/${bad_id}"
            else
                local -a sync_parts=()
                local sync_url_part="${explicit_sync#ab://}"
                local old_ifs=$IFS; IFS='/'
                read -r -a sync_parts <<< "$sync_url_part"
                IFS=$old_ifs
                local sync_branch="${sync_parts[0]}"
                local sync_target="${sync_parts[1]}"
                if [[ "$sync_branch" != "$diff_branch" || "$sync_target" != "$diff_target" ]]; then
                    fail_error "[$type_code] Conflict: --sync-manifest ($sync_branch/$sync_target) does not match manifest_diff ($diff_branch/$diff_target)."
                fi
                log_info "[$type_code] Explicit sync matches branch and target. Using explicit XML for environment lock."
            fi
        fi

        if [[ "$tree_path" == "UNRESOLVED_TREE_PATH" ]]; then
            local path_part="${build_value%%:*}"
            local abs_path
            abs_path=$(realpath -m "${path_part/#\~/$HOME}" 2>/dev/null || echo "${path_part/#\~/$HOME}")

            if [[ "$id_type" == "manifest_diff" ]]; then
                log_info "[$type_code] manifest_diff mode: setting tree_path to '$abs_path'"
                tree_path="$abs_path"
                project=""
            else
                local sync_url="${SYNC_MANIFEST_TARGETS[$type_code]}"
                if [[ -n "$sync_url" ]]; then
                    log_info "[$type_code] .repo not found. Deducing project boundary from manifest: $sync_url"
                    local cache_file=""
                    common_lib::fetch_manifest "$type_code" "$sync_url" cache_file
                    if (( $? != 0 )); then
                        fail_error "[$type_code] Manifest fetch failed while deducing project boundary."
                    fi

                    local matched_tree=""
                    local matched_proj=""

                    while IFS= read -r proj_path; do
                        if [[ -n "$proj_path" && "$abs_path" == *"/"$proj_path ]]; then
                            local potential_tree="${abs_path%/$proj_path}"
                            if [[ ${#proj_path} -gt ${#matched_proj} ]]; then
                                matched_proj="$proj_path"
                                matched_tree="$potential_tree"
                            fi
                        fi
                    done < <(xmlstarlet sel -t -m "//project" -v "@path" -n "$cache_file")

                    if [[ -n "$matched_tree" ]]; then
                        log_info "[$type_code] Deduced tree_path: $matched_tree, project: $matched_proj"
                        tree_path="$matched_tree"
                        project="$matched_proj"
                    else
                        fail_error "[$type_code] Could not deduce project boundary. Path '$abs_path' does not end with any project path defined in the manifest."
                    fi
                else
                    fail_error "[$type_code] Could not find .repo directory for path: $build_value. Please sync the manifest first so the project boundary can be determined."
                fi
            fi
        fi

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

        local is_newly_synced=false

        if [[ -n "${SYNC_MANIFEST_TARGETS[$type_code]}" && ! -d "$tree_path/.repo" ]]; then
            log_info "[$type_code] Tree '$tree_path' does not exist or is not a repo. Initializing it..."
            mkdir -p "$tree_path" || fail_error "[$type_code] Failed to create directory: $tree_path"

            local ab_url="${SYNC_MANIFEST_TARGETS[$type_code]}"
            local cache_file=""

            common_lib::fetch_manifest "$type_code" "$ab_url" cache_file
            if (( $? != 0 )); then
                fail_error "[$type_code] Manifest fetch/validation failed for $ab_url"
            fi

            local manifest_filename
            manifest_filename=$(basename "$cache_file")

            local manifest_url
            if [[ "$type_code" == "vkb" ]]; then
                # Vendor Kernel builds use partner-android
                manifest_url="https://partner-android.googlesource.com/kernel-pixel/manifest"
            elif [[ "$type_code" == "kb" ]]; then
                # Kernel builds
                manifest_url="sso://android/kernel/manifest"
            else
                # Platform (pb), System/GSI (sb), and Test (tb) builds default to platform manifest
                manifest_url="sso://android/platform/manifest"
            fi

            # Allow override via environment variable
            manifest_url="${REPO_INIT_MANIFEST_URL:-$manifest_url}"

            pushd "$tree_path" > /dev/null || fail_error "[$type_code] Failed to cd into $tree_path"
            if ! repo init -u "$manifest_url"; then
                log_info "[$type_code] Initial repo init with '$manifest_url' failed."
                local public_url="${manifest_url/sso:\/\/android\//https:\/\/android.googlesource.com\/}"
                if [[ "$public_url" != "$manifest_url" ]]; then
                    log_info "[$type_code] Retrying with public AOSP URL: $public_url"
                    rm -rf ".repo"
                    repo init -u "$public_url" || fail_error "[$type_code] Initial repo init failed with public URL: $public_url"
                else
                    fail_error "[$type_code] Initial repo init failed"
                fi
            fi
            cp "$cache_file" ".repo/manifests/" || fail_error "[$type_code] Failed to copy manifest"
            popd > /dev/null || fail_error "[$type_code] Failed to popd from $tree_path"

            common_lib::sync_tree_to_manifest "$tree_path" "$manifest_filename" "$type_code" || fail_error "[$type_code] repo sync failed"

            is_newly_synced=true
        fi

        if [[ "$id_type" != "ab" ]]; then
            TREE_PATHS[$type_code]="$tree_path"
            PROJECTS[$type_code]="$project"

            # 1. Check Android Source Tree Path
            if [[ ! -d "$tree_path" ]]; then
                fail_error "[$type_code] Android source tree path does not exist: $tree_path"
            fi
            if [[ "$(realpath "$tree_path")" == "$(realpath "$script_root_dir")" ]]; then
                fail_error "[$type_code] Android source tree path cannot be the same as the script's root directory."
            fi

            log_info "[$type_code] Checking for uncommitted changes in ${tree_path}..."
            check_uncommitted_changes "$type_code" "$tree_path" checked_trees

            if [[ -n "${SYNC_MANIFEST_TARGETS[$type_code]}" && "$is_newly_synced" != true ]]; then
                apply_custom_manifest "$type_code" "false"
                is_newly_synced=true
            fi
        fi

        if [[ "$id_type" == "range" || "$id_type" == "list" || "$id_type" == "fixed_commit" ]]; then
            log_info "[$type_code] Verifying git commit ranges..."
            verify_git_commit_ranges "$type_code" "$id_type" "$tree_path" "$project" target_ids has_bisection_target
        elif [[ "$id_type" == "manifest_diff" ]]; then
            log_info "[$type_code] Generating cross-project manifest diff..."
            local diff_branch="${target_ids[0]}"
            local diff_target="${target_ids[1]}"
            local good_id="${target_ids[2]}"
            local bad_id="${target_ids[3]}"

            local good_manifest_cache bad_manifest_cache
            common_lib::fetch_manifest "$type_code" "ab://${diff_branch}/${diff_target}/${good_id}" good_manifest_cache || fail_error "Failed to fetch GOOD manifest ($good_id)"
            common_lib::fetch_manifest "$type_code" "ab://${diff_branch}/${diff_target}/${bad_id}" bad_manifest_cache || fail_error "Failed to fetch BAD manifest ($bad_id)"

            local -a changed_projects=()
            common_lib::diff_manifests "$good_manifest_cache" "$bad_manifest_cache" changed_projects "$type_code" "${IGNORE_PROJECTS[@]}" || fail_error "Failed to diff manifests"

            if (( ${#changed_projects[@]} == 0 )); then
                fail_error "[$type_code] No projects changed between GOOD ($good_id) and BAD ($bad_id) manifests."
            fi

            local valid_project_index=0
            for ((i=0; i<${#changed_projects[@]}; i++)); do
                local line="${changed_projects[$i]}"
                local status="${line%%|*}"
                local rest="${line#*|}"
                local proj="${rest%%|*}"
                rest="${rest#*|}"
                local good_rev="${rest%%|*}"
                local bad_rev="${rest#*|}"

                if [[ "$status" == "ADDED" || "$status" == "REMOVED" ]]; then
                    log_warning "================================================================="
                    log_warning "WARNING: Project $proj was $status in the manifest diff."
                    log_warning "         Structural changes cannot be git-bisected and are SKIPPED."
                    log_warning "         If Initial State 0 fails to build later, this may be the cause!"
                    log_warning "================================================================="
                    continue
                fi

                if [[ "$status" == "IGNORED" ]]; then
                    log_info "[$type_code] Project '$proj' is explicitly ignored. Reverting and locking to GOOD ($good_rev)."
                    (cd "$tree_path/$proj" && git checkout "$good_rev" --quiet) || fail_error "[$type_code] Failed to checkout good_rev for ignored project $proj"
                    continue
                fi

                PROJECTS["${type_code}:$valid_project_index"]="$proj"
                GOOD_REVS["${type_code}:$valid_project_index"]="$good_rev"
                BAD_REVS["${type_code}:$valid_project_index"]="$bad_rev"
                local proj_abs_path="$tree_path/$proj"

                if [[ ! -d "$proj_abs_path" ]]; then
                    fail_error "[$type_code] Changed project directory missing: $proj_abs_path. Manifest may be incompatible."
                fi

                # Fetch commits between good_rev (exclusive) and bad_rev (inclusive)
                local -a commits_to_test=()
                get_commits_in_range "$proj_abs_path" "$good_rev" "$bad_rev" commits_to_test

                if (( ${#commits_to_test[@]} == 0 )); then
                    log_info "[$type_code] Skipped project $proj (no testable commits found between $good_rev and $bad_rev)"
                else
                    COMMITS_TO_TEST_MAP["${type_code}:$valid_project_index"]="${commits_to_test[*]}"
                    has_bisection_target=true
                    generate_ai_commit_report "$type_code" "candidate_commits" "$proj_abs_path" "$good_rev" "$bad_rev" "$proj"
                    valid_project_index=$((valid_project_index + 1))
                fi
            done
            PROJECT_COUNT[$type_code]=$valid_project_index

            if (( PROJECT_COUNT[$type_code] == 0 )); then
                fail_error "[$type_code] No bisectable projects found between GOOD ($good_id) and BAD ($bad_id) manifests. Only structural changes (Added/Removed) or untestable commits."
            fi
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

    log_info "Argument validation and processing completed successfully."
}


function save_initial_git_state() {
    local i
    local type_code="$1"

    if [[ "${ID_TYPES[$type_code]}" == "manifest_diff" ]]; then
        local num_projects="${PROJECT_COUNT[$type_code]:-0}"
        if (( num_projects == 0 )); then
            # Culprit project already found, only 1 project is being bisected
            local project_path="${TREE_PATHS[$type_code]}/${PROJECTS[$type_code]}"
            log_info "Saving initial git state for project: $project_path"
            local head_state
            head_state=$(cd "$project_path" && git symbolic-ref --short -q HEAD || git rev-parse HEAD)
            ORIGINAL_GIT_STATES[$type_code]="$head_state"
            log_info "[$type_code] Original HEAD is: ${head_state}"
        else
            for ((i=0; i<num_projects; i++)); do
                local project_path="${TREE_PATHS[$type_code]}/${PROJECTS["$type_code:$i"]}"
                log_info "Saving initial git state for project: $project_path"
                local head_state
                head_state=$(cd "$project_path" && git symbolic-ref --short -q HEAD || git rev-parse HEAD)
                ORIGINAL_GIT_STATES["$type_code:$i"]="$head_state"
                log_info "[$type_code:$i] Original HEAD is: ${head_state}"
            done
        fi
    else
        local project_path="${TREE_PATHS[$type_code]}/${PROJECTS[$type_code]}"
        log_info "Saving initial git state for project: $project_path"

        # Check for detached HEAD state
        local head_state
        head_state=$(cd "$project_path" && git symbolic-ref --short -q HEAD || git rev-parse HEAD)
        ORIGINAL_GIT_STATES[$type_code]="$head_state"
        log_info "[$type_code] Original HEAD is: ${head_state}"
    fi
}

function restore_all_git_states() {
    local key
    log_info "Restoring all modified git repositories to their original state..."
    for key in "${!ORIGINAL_GIT_STATES[@]}"; do
        local original_state="${ORIGINAL_GIT_STATES[$key]}"
        if [[ -z "$original_state" ]]; then
            continue
        fi

        local type_code="${key%%:*}"
        local project_path

        if [[ "$key" == *":"* ]]; then
            project_path="${TREE_PATHS[$type_code]}/${PROJECTS[$key]}"
        else
            project_path="${TREE_PATHS[$type_code]}/${PROJECTS[$type_code]}"
        fi

        if [[ -d "$project_path/.git" ]]; then
            log_info "Restoring project '$project_path' to '$original_state'..."
            pushd "$project_path" > /dev/null || fail_error "Failed to cd into $project_path"
            git checkout "$original_state" || fail_error "Failed to restore project '$project_path' to '$original_state'."
            popd > /dev/null || fail_error "Failed to popd from $project_path"
        fi
    done

    # Restore initial manifests
    local type_code
    for type_code in "${!ORIGINAL_MANIFESTS[@]}"; do
        local original_manifest="${ORIGINAL_MANIFESTS[$type_code]}"
        local tree_path="${TREE_PATHS[$type_code]}"
        if [[ -n "$original_manifest" && -d "$tree_path/.repo" ]]; then
            common_lib::sync_tree_to_manifest "$tree_path" "$original_manifest" "$type_code" || fail_error "Failed to restore manifest '$original_manifest' for $type_code"
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
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "clean_git" "$CLEAN_GIT"
    xml_util::add_attribute  xml_edit_cmd "/bisect/parameters" "with_setup_script" "$WITH_SETUP_SCRIPT"
    local type_code
    for type_code in "${!ORIGINAL_MANIFESTS[@]}"; do
        xml_util::add_element_with_attr xml_edit_cmd "/bisect/parameters" "parameter" "" "name" "original_manifest_${type_code}"
        xml_edit_cmd+=(-i "/bisect/parameters/parameter[@name='original_manifest_${type_code}']" -t attr -n "value" -v "${ORIGINAL_MANIFESTS[$type_code]}")
    done
    for type_code in "${!SYNC_MANIFEST_TARGETS[@]}"; do
        xml_util::add_element_with_attr xml_edit_cmd "/bisect/parameters" "parameter" "" "name" "sync_manifest_${type_code}"
        xml_edit_cmd+=(-i "/bisect/parameters/parameter[@name='sync_manifest_${type_code}']" -t attr -n "value" -v "${SYNC_MANIFEST_TARGETS[$type_code]}")
    done
    local test
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
            local index xpath_idx commit
            for index in "${!commits_arr[@]}"; do
                xpath_idx=$((index + 1))
                commit="${commits_arr[$index]}"
                # Add change with default "unknown" status
                xml_util::add_element_with_attr xml_edit_cmd "/bisect/$node_name" "change" "$commit" "status" "unknown"
                xml_util::add_attribute xml_edit_cmd "/bisect/$node_name/change[${xpath_idx}]" "index" "$index"
            done
        elif [[ "${ID_TYPES[$type_code]}" == "manifest_diff" ]]; then
            local node_name="${var_name,,}s" # e.g., platform_builds
            xml_util::add_node       xml_edit_cmd "/bisect" "$node_name"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$node_name" "id_type" "${ID_TYPES[$type_code]}"
            xml_util::add_attribute  xml_edit_cmd "/bisect/$node_name" "path" "${TREE_PATHS[$type_code]}"

            xml_util::add_node xml_edit_cmd "/bisect/$node_name" "project_bisection"
            local num_projects="${PROJECT_COUNT[$type_code]}"
            xml_util::add_attribute xml_edit_cmd "/bisect/$node_name/project_bisection" "good_index" "0"
            xml_util::add_attribute xml_edit_cmd "/bisect/$node_name/project_bisection" "bad_index" "$num_projects"

            local i proj_idx proj good_rev bad_rev status
            for ((i=1; i<=num_projects; i++)); do
                proj_idx=$((i-1))
                proj="${PROJECTS["${type_code}:$proj_idx"]}"
                good_rev="${GOOD_REVS["${type_code}:$proj_idx"]}"
                bad_rev="${BAD_REVS["${type_code}:$proj_idx"]}"

                status="unknown"
                if (( i == num_projects )); then
                    status="bad"
                fi

                xml_util::add_element_with_attr xml_edit_cmd "/bisect/$node_name/project_bisection" "split_state" "" "index" "$i"
                xml_util::add_attribute xml_edit_cmd "/bisect/$node_name/project_bisection/split_state[$i]" "project_made_bad" "$proj"
                xml_util::add_attribute xml_edit_cmd "/bisect/$node_name/project_bisection/split_state[$i]" "status" "$status"
                xml_util::add_attribute xml_edit_cmd "/bisect/$node_name/project_bisection/split_state[$i]" "good_rev" "$good_rev"
                xml_util::add_attribute xml_edit_cmd "/bisect/$node_name/project_bisection/split_state[$i]" "bad_rev" "$bad_rev"
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
    local type_code
    local i
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
    CLEAN_GIT=$(xml_util::read_value "/bisect/parameters/@clean_git")
    WITH_SETUP_SCRIPT=$(xml_util::read_value "/bisect/parameters/@with_setup_script")
    xml_util::read_values_to_array "/bisect/parameters/test" TEST_NAME

    for type_code in "pb" "kb" "vkb" "sb"; do
        local original_manifest
        original_manifest=$(xml_util::read_value "/bisect/parameters/parameter[@name='original_manifest_${type_code}']/@value")
        if [[ -n "$original_manifest" ]]; then
            ORIGINAL_MANIFESTS[$type_code]="$original_manifest"
        fi

        local sync_manifest
        sync_manifest=$(xml_util::read_value "/bisect/parameters/parameter[@name='sync_manifest_${type_code}']/@value")
        if [[ -n "$sync_manifest" ]]; then
            SYNC_MANIFEST_TARGETS[$type_code]="$sync_manifest"
        fi
    done

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
            local commit status
            for i in "${!commits_arr[@]}"; do
                commit="${commits_arr[$i]}"
                status="${statuses_arr[$i]}"
                COMMIT_STATUSES["$type_code:$i"]="$status"
            done

            if [[ "${IS_BREAKING[$type_code]}" == "true" ]]; then
                BISECT_BUILD_TYPES+=("$type_code")
            fi
            # Must save the initial state for cleanup on resume
            save_initial_git_state "$type_code"
        elif [[ "$id_type" == "manifest_diff" ]]; then
            has_bisection_node=true
            ID_TYPES[$type_code]="$id_type"
            TREE_PATHS[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/@path")

            local bisection_node_count
            bisection_node_count=$(xml_util::read_value "count(/bisect/$plural_node_name/project_bisection)")
            if [[ "$bisection_node_count" -gt 0 ]]; then
                GOOD_INDICES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/project_bisection/@good_index")
                BAD_INDICES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/project_bisection/@bad_index")

                local -a split_projs=()
                local -a split_statuses=()
                local -a split_good_revs=()
                local -a split_bad_revs=()

                xml_util::read_attributes_to_array "/bisect/$plural_node_name/project_bisection/split_state/@project_made_bad" split_projs
                xml_util::read_attributes_to_array "/bisect/$plural_node_name/project_bisection/split_state/@status" split_statuses
                xml_util::read_attributes_to_array "/bisect/$plural_node_name/project_bisection/split_state/@good_rev" split_good_revs
                xml_util::read_attributes_to_array "/bisect/$plural_node_name/project_bisection/split_state/@bad_rev" split_bad_revs

                PROJECT_COUNT[$type_code]=${#split_projs[@]}

                local proj_abs_path
                local -a commits_to_test
                for i in "${!split_projs[@]}"; do
                    PROJECTS["$type_code:$i"]="${split_projs[$i]}"
                    GOOD_REVS["$type_code:$i"]="${split_good_revs[$i]}"
                    BAD_REVS["$type_code:$i"]="${split_bad_revs[$i]}"

                    # Dynamically reconstruct COMMITS_TO_TEST_MAP without side-effects
                    proj_abs_path="${TREE_PATHS[$type_code]}/${split_projs[$i]}"
                    commits_to_test=()
                    get_commits_in_range "$proj_abs_path" "${split_good_revs[$i]}" "${split_bad_revs[$i]}" commits_to_test
                    COMMITS_TO_TEST_MAP["$type_code:$i"]="${commits_to_test[*]}"
                done
            fi

            local project_node_count
            project_node_count=$(xml_util::read_value "count(/bisect/$plural_node_name/project)")
            if [[ "$project_node_count" -gt 0 ]]; then
                # Script has found the culprit project and entered Commit-Level Bisection
                PROJECTS[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/project/@name")
                GOOD_INDICES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/project/@good_index")
                BAD_INDICES[$type_code]=$(xml_util::read_value "/bisect/$plural_node_name/project/@bad_index")
                IS_BREAKING[$type_code]="true"
                BISECT_BUILD_TYPES+=("$type_code")

                # Restore baseline for the other projects during resume
                local bad_idx_for_baseline
                bad_idx_for_baseline=$(xml_util::read_value "/bisect/$plural_node_name/project_bisection/@bad_index")
                if [[ -n "$bad_idx_for_baseline" ]]; then
                    local culprit_proj_idx=$(( bad_idx_for_baseline - 1 ))
                    log_info "Resuming commit-level bisection. Restoring baseline to split_${culprit_proj_idx}."
                    checkout_manifest_diff_split_state "$type_code" "$culprit_proj_idx"
                fi

                local -a commits_arr=()
                local -a statuses_arr=()
                xml_util::read_values_to_array "/bisect/$plural_node_name/project/change" commits_arr
                xml_util::read_attributes_to_array "/bisect/$plural_node_name/project/change/@status" statuses_arr
                COMMITS_TO_TEST_MAP[$type_code]="${commits_arr[*]}"

                for i in "${!commits_arr[@]}"; do
                    COMMIT_STATUSES["$type_code:$i"]="${statuses_arr[$i]}"
                done
            fi

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
                    local -a target_ids=()
                    local parsed_type=""
                    common_lib::parse_change_string "$build_val" tree_path project target_ids parsed_type
                    TREE_PATHS[$type_code]="$tree_path"
                    PROJECTS[$type_code]="$project"
                    COMMITS_TO_TEST_MAP[$type_code]="${target_ids[0]}" # Store the single commit
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

function update_commit_status_in_xml() {
    local type_code="$1"
    local commit_index="$2" # This is the 0-based index
    local status="$3"

    local var_name="${BUILD_TYPE_MAP[$type_code]}"
    local node_name="${var_name,,}s"

    local change_xpath="/bisect/$node_name"
    if [[ -n "${PROJECTS[$type_code]:-}" ]]; then
        change_xpath+="/project[@name='${PROJECTS[$type_code]}']"
    fi
    change_xpath+="/change[@index='$commit_index']"

    xml_util::update_xml_attribute "${change_xpath}" "status" "$status"
}

# --- Test Suite Caching ---
function get_test_suite_base_dir() {
    echo "$DOWNLOAD_PATH"
}

function handle_test_suite_url() {
    local i
    local test_suite_url="$1"
    log_info "Test suite provided as a URL. Preparing for download..."

    local branch target build_id filename
    common_lib::parse_artifact_url "$test_suite_url" branch target build_id _ filename || fail_error "Failed to parse URL."

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
    common_lib::parse_artifact_url "$required_locator" branch target build_id _ filename || fail_error "Failed to parse URL."

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

    if "$CLEAN_GIT"; then
        log_info "Cleaning project '$project_path' with git clean -fdx..."
        (cd "$project_path" && git clean -fdx) || log_warn "Failed to clean '$project_path'. Proceeding anyway."
    fi

    log_info "Checking out commit '$commit_hash' in project '$project_path'..."
    (cd "$project_path" && git checkout "$commit_hash")
    if (( $? != 0 )); then
        log_error "Failed to checkout commit '$commit_hash' in '$project_path'."
        return 1
    fi
    return 0
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
    local skip_val
    for skip_val in $skipped_string; do
        skipped_set["$skip_val"]=1
    done

    local -a candidates=()

    # Find candidates between (low_bound, high_bound)
    local i
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

        common_lib::enter_interactive_fix_mode "Custom setup script failed." "$NON_INTERACTIVE"
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
    local arg
    local type_code
    local -A builds_to_use
    for arg in "$@"; do
        type_code="${arg%%:*}"
        local value="${arg#*:}" # Can be commit hash or ab:// URL or local path
        builds_to_use[$type_code]="$value"
    done

    # 1. Checkout all necessary commits (bisection targets + fixed_commit)
    log_info "--- Test Combination ---"
    # 1.1 Checkout bisection targets
    local split_value split_idx
    for type_code in "${!builds_to_use[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "range" || "${ID_TYPES[$type_code]}" == "list" ]]; then
            log_info "  - ${type_code} [BISECT] (${PROJECTS[$type_code]}): ${builds_to_use[$type_code]}"
            checkout_commit "$type_code" "${builds_to_use[$type_code]}" || return 1 # Propagate failure
        elif [[ "${ID_TYPES[$type_code]}" == "manifest_diff" ]]; then
            if [[ "${IS_BREAKING[$type_code]:-}" == "true" ]]; then
                log_info "  - ${type_code} [BISECT] (${PROJECTS[$type_code]}): ${builds_to_use[$type_code]}"
                checkout_commit "$type_code" "${builds_to_use[$type_code]}" || return 1 # Propagate failure
            else
                split_value="${builds_to_use[$type_code]}"
                if [[ "$split_value" != split_* ]]; then
                    fail_error "Internal error: Expected 'split_' prefix for manifest_diff in Phase 1, got '$split_value' for $type_code"
                fi
                split_idx="${split_value#split_}"

                if [[ "${CURRENT_SPLIT_STATES[$type_code]:-}" != "$split_idx" ]]; then
                    fail_error "Internal error: Workspace for $type_code is not at split state $split_idx. (Currently at: ${CURRENT_SPLIT_STATES[$type_code]:-none}). Expected checkout_manifest_diff_split_state to be called first."
                fi

                log_info "  - ${type_code} [BISECT_SPLIT] (Multiple Projects): Split Index $split_idx"
                # Checkout is handled externally by checkout_manifest_diff_split_state before calling this function
            fi
        fi
    done
    # 1.2 Checkout fixed_commit dependencies
    log_info "--- Checking out fixed_commit dependencies ---"
    local commit_hash
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "fixed_commit" ]]; then
            commit_hash="${COMMITS_TO_TEST_MAP[$type_code]}"
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
    local id_type arg_val var_name
    for type_code in pb kb vkb sb; do
        id_type="${ID_TYPES[$type_code]}"
        if [[ -z "$id_type" ]]; then
            continue
        fi

        arg_val=""
        if [[ "$id_type" == "none" ]]; then
            arg_val="none"
        elif [[ "$id_type" == "range" || "$id_type" == "list" || "$id_type" == "fixed_commit" || "$id_type" == "manifest_diff" ]]; then
            # For all git-based types, we pass the path to the Android tree
            arg_val="${TREE_PATHS[$type_code]}"
        else
            # For "ab" or "local" types
            var_name="${BUILD_TYPE_MAP[$type_code]}"
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
            common_lib::enter_interactive_fix_mode "Device setup (build/flash) failed." "$NON_INTERACTIVE"
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
    local test
    local i
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

    local log_dir="$OUTPUT_DIR/test_logs"
    if [[ -n "${CURRENT_TEST_LOG_PREFIX:-}" ]]; then
        log_dir="$log_dir/$CURRENT_TEST_LOG_PREFIX"
    fi
    mkdir -p "$log_dir"

    local -a test_cmd=("$RUN_TEST_SCRIPT" "-td" "$TEST_DIR" "-tl" "$log_dir")
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


function build_test_combination_args() {
    local target_type="$1"
    local target_commit="$2"
    local -n combination_ref="$3"
    local type_code
    local other_type

    combination_ref=()

    if [[ -n "$target_type" && -n "$target_commit" ]]; then
        combination_ref+=("${target_type}:${target_commit}")
    fi

    # Add "good" commit for other bisection targets
    local -a other_commits
    for other_type in "${!BUILD_TYPE_MAP[@]}"; do
        if [[ "$other_type" == "$target_type" || -z "${ID_TYPES[$other_type]:-}" ]]; then
            continue
        fi
        if [[ "${ID_TYPES[$other_type]}" == "range" || "${ID_TYPES[$other_type]}" == "list" ]]; then
            other_commits=(${COMMITS_TO_TEST_MAP[$other_type]})
            combination_ref+=("${other_type}:${other_commits[0]}")
        elif [[ "${ID_TYPES[$other_type]}" == "manifest_diff" ]]; then
            if [[ "${IS_BREAKING[$other_type]:-}" == "true" ]]; then
                other_commits=(${COMMITS_TO_TEST_MAP[$other_type]})
                combination_ref+=("${other_type}:${other_commits[0]}")
            else
                combination_ref+=("${other_type}:split_0")
            fi
        fi
    done

    # Add fixed dependencies (ab, local, fixed_commit)
    local var_name
    for type_code in "${!BUILD_TYPE_MAP[@]}"; do
         if [[ "${ID_TYPES[$type_code]:-}" != "range" && "${ID_TYPES[$type_code]:-}" != "list" && "${ID_TYPES[$type_code]:-}" != "manifest_diff" ]]; then
            var_name="${BUILD_TYPE_MAP[$type_code]}"
            if [[ -n "${!var_name}" ]]; then
                combination_ref+=("${type_code}:${!var_name}")
            fi
         fi
    done
}

function validate_and_identify_breakage() {
    local type_code
    local type_to_check
    log_info "--- Step 1: Validating the initial 'all good' commit combination ---"
    local -a ranged_build_types=()
    for type_code in "${!ID_TYPES[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "range" || "${ID_TYPES[$type_code]}" == "list" ]]; then
            ranged_build_types+=("$type_code")
        fi
    done

    local -a combination=()
    build_test_combination_args "" "" combination

    log_info "Testing with initial good combination: ${combination[*]}"
    CURRENT_TEST_LOG_PREFIX="boundary_initial_good"

    # For manifest_diff, the workspace is currently at the Bad manifest.
    # We must checkout the initial 'all good' split state (Index 0) before testing.
    for type_code in "${!ID_TYPES[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "manifest_diff" && "${IS_BREAKING[$type_code]}" != "true" ]]; then
            log_info "[$type_code] Checking out 'all good' split state (Index 0) for boundary validation."
            checkout_manifest_diff_split_state "$type_code" 0
            if (( $? != 0 )); then
                fail_error "Failed to checkout initial good split state for $type_code"
            fi
        fi
    done

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
        local last_commit="${commits_for_type[$last_commit_index]}"

        build_test_combination_args "$type_to_check" "$last_commit" test_combination

        log_info "Checking for breakage in '${type_to_check}' using combination: ${test_combination[*]}"
        CURRENT_TEST_LOG_PREFIX="boundary_test_${type_to_check}_${last_commit:0:8}"
        setup_and_test_combination "${test_combination[@]}"
        local test_status=$?

        local var_name="${BUILD_TYPE_MAP[$type_to_check]}"
        local node_name="${var_name,,}s"
        if (( test_status != 0 )); then
            log_info "RESULT: Found breaking project: ${type_to_check}"
            BISECT_BUILD_TYPES+=("$type_to_check")
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

    local has_active_manifest_diff=false
    for type_code in "${!ID_TYPES[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "manifest_diff" && "${IS_BREAKING[$type_code]}" != "true" ]]; then
            has_active_manifest_diff=true
            break
        fi
    done

    if (( ${#BISECT_BUILD_TYPES[@]} == 0 )) && ! $has_active_manifest_diff; then
        fail_error "Validation failed: No breaking projects were identified. The combination of all LAST commits seems to be passing."
    fi
    log_info "Validation complete. Breaking projects to be bisected: ${BISECT_BUILD_TYPES[*]}"
}

function checkout_manifest_diff_split_state() {
    local i
    local type_code="$1"
    local split_idx="$2"
    local num_projects="${PROJECT_COUNT[$type_code]}"
    local tree_path="${TREE_PATHS[$type_code]}"

    log_info "--- Checking out projects for Split State $split_idx ---"
    for ((i=0; i<num_projects; i++)); do
        local proj="${PROJECTS["$type_code:$i"]}"
        local commit
        if (( i < split_idx )); then
            commit="${BAD_REVS["$type_code:$i"]}"
        else
            commit="${GOOD_REVS["$type_code:$i"]}"
        fi
        local proj_abs_path="$tree_path/$proj"
        log_info "  - ${type_code} [SPLIT:$split_idx] ($proj): $commit"

        pushd "$proj_abs_path" > /dev/null || return 1
        git checkout -q "$commit" || {
            log_error "Failed to checkout $commit in $proj_abs_path"
            popd > /dev/null
            return 1
        }
        popd > /dev/null
    done

    # Record the successful checkout
    CURRENT_SPLIT_STATES["$type_code"]="$split_idx"
    return 0
}

function bisect_projects_in_manifest_diff() {
    local i
    local c_idx
    local type_code="$1"
    local num_projects="${PROJECT_COUNT[$type_code]}"

    log_info "========================================="
    log_info "Starting Project-Level Bisection for: $type_code"
    log_info "========================================="

    local var_name="${BUILD_TYPE_MAP[$type_code]}"
    local plural_node_name="${var_name,,}s"

    local good_idx=$(xml_util::read_value "/bisect/$plural_node_name/project_bisection/@good_index")
    local bad_idx=$(xml_util::read_value "/bisect/$plural_node_name/project_bisection/@bad_index")

    if [[ -z "$good_idx" || -z "$bad_idx" ]]; then
        good_idx=0
        bad_idx=$num_projects
        xml_util::update_xml_attribute "/bisect/$plural_node_name/project_bisection" "good_index" "$good_idx"
        xml_util::update_xml_attribute "/bisect/$plural_node_name/project_bisection" "bad_index" "$bad_idx"
    fi

    local skipped_indices_string=""
    for ((i=1; i<=num_projects; i++)); do
        local st=$(xml_util::read_value "/bisect/$plural_node_name/project_bisection/split_state[$i]/@status")
        if [[ "$st" == "skipped" ]]; then
            skipped_indices_string+=" $i"
        fi
    done

    while (( good_idx + 1 < bad_idx )); do
        local mid_idx
        mid_idx=$(find_real_middle_index "$good_idx" "$bad_idx" "$skipped_indices_string")
        if (( $? != 0 )); then
            log_warn "Project-Level Bisection stuck. No testable splits between $good_idx and $bad_idx."
            break
        fi

        checkout_manifest_diff_split_state "$type_code" "$mid_idx"
        if (( $? != 0 )); then
            fail_error "Failed to checkout split state $mid_idx"
        fi

        local -a test_combination=()
        build_test_combination_args "$type_code" "split_${mid_idx}" test_combination

        CURRENT_TEST_LOG_PREFIX="bisect_proj_${type_code}_split${mid_idx}"

        setup_and_test_combination "${test_combination[@]}"
        local test_status=$?

        if (( test_status == 0 )); then
            log_info "RESULT: Split State $mid_idx is GOOD."
            good_idx=$mid_idx
            xml_util::update_xml_attribute "/bisect/$plural_node_name/project_bisection" "good_index" "$good_idx"
            xml_util::update_xml_attribute "/bisect/$plural_node_name/project_bisection/split_state[$mid_idx]" "status" "good"
        elif (( test_status == 125 )); then
            log_warn "RESULT: Split State $mid_idx is SKIPPED."
            skipped_indices_string+=" $mid_idx"
            xml_util::update_xml_attribute "/bisect/$plural_node_name/project_bisection/split_state[$mid_idx]" "status" "skipped"
        elif (( test_status > 0 && test_status < 128 )); then
            log_info "RESULT: Split State $mid_idx is BAD."
            bad_idx=$mid_idx
            xml_util::update_xml_attribute "/bisect/$plural_node_name/project_bisection" "bad_index" "$bad_idx"
            xml_util::update_xml_attribute "/bisect/$plural_node_name/project_bisection/split_state[$mid_idx]" "status" "bad"
        else
            fail_error "Test aborted with status $test_status"
        fi
    done

    local culprit_proj_idx=$(( bad_idx - 1 ))

    # Restore baseline to split_${culprit_proj_idx} for commit-level bisection
    log_info "Restoring baseline to split_${culprit_proj_idx} for commit-level bisection."
    if ! checkout_manifest_diff_split_state "$type_code" "$culprit_proj_idx"; then
        fail_error "Failed to restore baseline split state $culprit_proj_idx for $type_code before moving to commit-level bisection."
    fi

    local culprit_proj="${PROJECTS["$type_code:$culprit_proj_idx"]}"
    log_info "========================================="
    log_info "Culprit Project Found: $culprit_proj"
    log_info "========================================="

    local -a commits_to_test=(${COMMITS_TO_TEST_MAP["$type_code:$culprit_proj_idx"]})

    if (( ${#commits_to_test[@]} == 0 )); then
        log_warn "Project-Level Bisection identified culprit project '$culprit_proj', but no testable commits were found."
        log_warn "Skipping commit-level bisection for $type_code."
        return $EXIT_SUCCESS
    fi

    local last_commit_index=$(( ${#commits_to_test[@]} - 1 ))

    local -a xml_edit_cmd=()
    xml_util::add_element_with_attr xml_edit_cmd "/bisect/$plural_node_name" "project" "" "name" "$culprit_proj"

    local proj_xpath="/bisect/$plural_node_name/project[@name='$culprit_proj']"

    xml_util::add_attribute xml_edit_cmd "$proj_xpath" "status" "bisecting"
    xml_util::add_attribute xml_edit_cmd "$proj_xpath" "good_index" "0"
    xml_util::add_attribute xml_edit_cmd "$proj_xpath" "bad_index" "$last_commit_index"

    for c_idx in "${!commits_to_test[@]}"; do
        local xpath_idx=$(( c_idx + 1 ))
        local commit="${commits_to_test[$c_idx]}"
        local st="unknown"
        if (( c_idx == 0 )); then st="good"; fi
        if (( c_idx == last_commit_index )); then st="bad"; fi

        xml_util::add_element_with_attr xml_edit_cmd "$proj_xpath" "change" "$commit" "status" "$st"
        xml_util::add_attribute xml_edit_cmd "$proj_xpath/change[${xpath_idx}]" "index" "$c_idx"
    done
    xml_util::execute_edits xml_edit_cmd

    PROJECTS[$type_code]="$culprit_proj"
    COMMITS_TO_TEST_MAP[$type_code]="${commits_to_test[*]}"
    GOOD_INDICES[$type_code]=0
    BAD_INDICES[$type_code]=$last_commit_index
    IS_BREAKING[$type_code]="true"
    BISECT_BUILD_TYPES+=("$type_code")
    for c_idx in "${!commits_to_test[@]}"; do
        local st="unknown"
        if (( c_idx == 0 )); then st="good"; fi
        if (( c_idx == last_commit_index )); then st="bad"; fi
        COMMIT_STATUSES["$type_code:$c_idx"]="$st"
    done
}

function bisect_single_project() {
    local i
    local type_code_to_bisect="$1"
    log_info "========================================="
    log_info "Starting Bisection Loop for: $type_code_to_bisect"
    log_info "========================================="

    local good_idx=${GOOD_INDICES[$type_code_to_bisect]}
    local bad_idx=${BAD_INDICES[$type_code_to_bisect]}
    local -a commits_to_test=(${COMMITS_TO_TEST_MAP[$type_code_to_bisect]})

    local var_name="${BUILD_TYPE_MAP[$type_code_to_bisect]}"
    local node_name="${var_name,,}s"

    local target_xpath="/bisect/$node_name"
    if [[ -n "${PROJECTS[$type_code_to_bisect]:-}" ]]; then
        target_xpath+="/project[@name='${PROJECTS[$type_code_to_bisect]}']"
    fi

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
        build_test_combination_args "$type_code_to_bisect" "$mid_commit" test_combination

        log_info "Testing with combination: ${test_combination[*]}"
        CURRENT_TEST_LOG_PREFIX="bisect_${type_code_to_bisect}_idx${mid_idx}_${mid_commit:0:8}"
        setup_and_test_combination "${test_combination[@]}"
        local test_status=$?

        if (( test_status == 0 )); then # GOOD
            log_info "RESULT: Commit ${mid_commit:0:12} ($type_code_to_bisect) is GOOD."
            good_idx=$mid_idx
            GOOD_INDICES[$type_code_to_bisect]=$good_idx
            xml_util::update_xml_attribute "$target_xpath" "good_index" "$good_idx"
            update_commit_status_in_xml "$type_code_to_bisect" "$mid_idx" "good"
            COMMIT_STATUSES["$type_code_to_bisect:$mid_idx"]="good"
        elif (( test_status == 125 )); then # SKIP
            log_warn "RESULT: Commit ${mid_commit:0:12} ($type_code_to_bisect) is SKIPPED."
            # Add to our in-memory list of skipped indices
            skipped_indices_string+=" $mid_idx"
            COMMIT_STATUSES["$type_code_to_bisect:$mid_idx"]="skipped"
            update_commit_status_in_xml "$type_code_to_bisect" "$mid_idx" "skipped"
            # DO NOT update good_idx or bad_idx, let the loop try again
        elif (( test_status > 0 && test_status < 128 )); then # BAD (1-124, including 1 for test fail)
            log_info "RESULT: Commit ${mid_commit:0:12} ($type_code_to_bisect) is BAD/BROKEN."
            bad_idx=$mid_idx
            BAD_INDICES[$type_code_to_bisect]=$bad_idx
            xml_util::update_xml_attribute "$target_xpath" "bad_index" "$bad_idx"
            if (( test_status == 1 )); then
                 update_commit_status_in_xml "$type_code_to_bisect" "$mid_idx" "bad" # Test failed
                 COMMIT_STATUSES["$type_code_to_bisect:$mid_idx"]="bad"
            else
                 update_commit_status_in_xml "$type_code_to_bisect" "$mid_idx" "broken" # User marked bad/broken
                 COMMIT_STATUSES["$type_code_to_bisect:$mid_idx"]="broken"
            fi
        else # ABORT (128+)
            log_error "Bisection aborted by user (exit code $test_status)!"
            update_commit_status_in_xml "$type_code_to_bisect" "$mid_idx" "abort"
            xml_util::update_xml_node "/bisect/state/@status" "aborted"
            exit "$test_status"
        fi
        log_info "New Range for $type_code_to_bisect: Index $good_idx (Good) to $bad_idx (Bad)"
    done

    xml_util::update_xml_attribute "$target_xpath" "status" "complete"
}

function bisect_all_breaking_projects() {
    local type_code
    local b
    for type_code in "${BISECT_ORDER[@]}"; do
        local found=false
        for b in "${BISECT_BUILD_TYPES[@]}"; do
            if [[ "$b" == "$type_code" ]]; then
                found=true
                break
            fi
        done
        if $found; then
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

        # Generate commit metadata report for AI analysis
        local full_repo_path="${TREE_PATHS[$type_code]}"
        if [[ -n "$project_path" ]]; then
            full_repo_path="${full_repo_path}/${project_path}"
        fi
        generate_ai_commit_report "$type_code" "culprit_commits" "$full_repo_path" "$last_good_commit" "$first_bad_commit" "$project_path"
    done
}

function exit_if_dry_run() {
    if "$DRY_RUN"; then
        log_info "Dry run completed. Bisection XML file created at: $BISECT_CONFIG_FILE"
        exit 0
    fi
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
        load_state_from_xml
        restore_workspace_state
    else
        validate_and_process_args
        log_info "Starting new bisection run..."
        init_bisect_file
        exit_if_dry_run
        load_state_from_xml
    fi

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

    local type_code
    for type_code in "${!ID_TYPES[@]}"; do
        if [[ "${ID_TYPES[$type_code]}" == "manifest_diff" && "${IS_BREAKING[$type_code]}" != "true" ]]; then
            bisect_projects_in_manifest_diff "$type_code"
        fi
    done

    bisect_all_breaking_projects
}

# Execute main
main "$@"