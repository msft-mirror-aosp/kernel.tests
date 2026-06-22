#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# Common Script Library for kernel test tools

# --- Include Guard ---
# Prevents the library from being sourced multiple times.

if [[ -n "${__COMMON_LIB_SOURCED__:-}" ]]; then
    return 0
fi
readonly __COMMON_LIB_SOURCED__=1

# --- Exit Codes & Status Constants ---
# Standard exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_SETUP_FAILED=255

# Test specific status codes (aliases for readability)
readonly TEST_PASSED=0
readonly TEST_FAILED=1

# --- Constants ---
readonly FETCH_SCRIPT_PATH_IN_REPO="kernel/tests/tools/fetch_artifact.sh"
readonly KERNEL_JDK_PATH="prebuilts/jdk/jdk11/linux-x86"
readonly LOCAL_JDK_PATH="/usr/local/buildtools/java/jdk11"
readonly PLATFORM_JDK_PATH="prebuilts/jdk/jdk21/linux-x86"
readonly DEFAULT_BUILD_CHECKER=/google/data/ro/projects/android/ab
readonly DEFAULT_FETCH_ARTIFACT="/google/data/ro/projects/android/fetch_artifact"

# --- BinFS ---
readonly COMMON_LIB_CL_FLASH_CLI="/google/bin/releases/android/flashstation/cl_flashstation"
readonly COMMON_LIB_LOCAL_FLASH_CLI="/google/bin/releases/android/flashstation/local_flashstation"

# --- Download Path ---
if [[ -d "/tmp" ]]; then
    readonly DOWNLOAD_PATH="/tmp/kernel_tests_downloads"
elif [[ -d "$HOME/Downloads" ]]; then
    readonly DOWNLOAD_PATH="$HOME/Downloads/kernel_tests_downloads"
else
    readonly DOWNLOAD_PATH="$PWD/out/kernel_tests_downloads"
fi

# --- Device artifacts ----
readonly DEVICE_DIR="$DOWNLOAD_PATH/device_dir"
readonly VENDOR_KERNEL_DIR="$DOWNLOAD_PATH/vendor_kernel_dir"
readonly KERNEL_DIR="$DOWNLOAD_PATH/kernel_dir"
readonly GSI_DIR="$DOWNLOAD_PATH/gsi_dir"
readonly TRADEFED_DIR="$DOWNLOAD_PATH/tradefed_dir"

# --- Internal State Flags ---
__COMMON_LIB_NO_TPUT__="" # Flag set if tput is unavailable

# --- Dependency Checks ---
if ! command -v tput &> /dev/null; then
    echo "[WARN] common_lib.sh: Command 'tput' not found. Colored output disabled." >&2
    __COMMON_LIB_NO_TPUT__=1
fi

if ! command -v repo &> /dev/null; then
    echo "[ERROR] common_lib.sh: Required command 'repo' not found. This library needs 'repo'." >&2
    return $EXIT_FAILURE
fi

if ! command -v date &> /dev/null; then
    echo "[ERROR] common_lib.sh: Required command 'date' not found. Timestamping will fail." >&2
    return $EXIT_FAILURE
fi

# --- Color Constants ---
# Initialize empty, setup if tput exists and stdout is a terminal.
BLUE=""
BOLD=""
END=""
GREEN=""
ORANGE=""
RED=""
YELLOW=""
if [[ -z "$__COMMON_LIB_NO_TPUT__" && -t 1 ]]; then
    BLUE=$(tput setaf 4 2>/dev/null)
    BOLD=$(tput bold 2>/dev/null)
    END=$(tput sgr0 2>/dev/null)
    GREEN=$(tput setaf 2 2>/dev/null)
    ORANGE=$(tput setaf 208 2>/dev/null || tput setaf 3 2>/dev/null) # Fallback orange
    RED=$(tput setaf 198 2>/dev/null || tput setaf 1 2>/dev/null)    # Fallback red
    YELLOW=$(tput setaf 3 2>/dev/null)

    # Basic check if tput commands worked (might fail on minimal terminals)
    if [[ -z "$BLUE" || -z "$BOLD" || -z "$END" ]]; then
        echo "[WARN] common_lib.sh: tput commands failed to set colors properly. Disabling colors." >&2
        BLUE="" BOLD="" END="" GREEN="" ORANGE="" RED="" YELLOW=""
    fi
fi
# Make color variables readonly after setting
readonly BLUE BOLD END GREEN ORANGE RED YELLOW

# --- Internal Helper ---

function _timestamp() {
    local ts=""
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    if ts=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null); then
        printf "%s" "$ts"
        return $EXIT_SUCCESS
    else
        # If date command fails entirely
        printf "TIMESTAMP_ERR" >&2 # Avoid calling log_error to prevent recursion
        return $EXIT_FAILURE
    fi
}

function _print_log() {
    local log_level="$1"
    local color_code="$2"
    local message="$3"
    local exit_code="${4:-}" # Optional exit code for context
    local external_frame_hint="${5:-}"
    local timestamp
    timestamp=$(_timestamp) || timestamp="TIMESTAMP_ERR"

    local frame_to_report # This will hold the final frame number for 'caller'
    if [[ -n "$external_frame_hint" && "$external_frame_hint" =~ ^[0-9]+$ ]]; then
        # If an explicit frame hint is provided and is a number, use it directly.
        frame_to_report="$external_frame_hint"
    else
        frame_to_report=1
        if [[ -n "$external_frame_hint" && ! "$external_frame_hint" =~ ^[0-9]+$ ]]; then
            echo "[WARN] common_lib.sh: Invalid external_frame_hint '$external_frame_hint' provided to _print_log. Using default frame 1." >&2
        fi
    fi

    # Get caller info (line, function, script) - 'caller 1' gets info about the caller of log_info/warn/error
    local caller_info
    caller_info=$(caller "$frame_to_report" 2>/dev/null) || caller_info="? <unknown> <unknown>"

    # Simple parsing of caller output (e.g., "123 my_func ./script.sh")
    local caller_line="" caller_function="" caller_path="" caller_file="" context_info=""
    if read -r caller_line caller_function caller_path <<< "$caller_info"; then
        caller_file=$(basename "$caller_path")
        context_info="$caller_file:$caller_line ($caller_function)"
    else
        context_info="${caller_info}" # Fallback if parsing fails
    fi

    # Format: TIMESTAMP LEVEL [script:line (function)]: Message
    local log_prefix="${timestamp} ${log_level}"
    local full_message_prefix="[${log_prefix} ${context_info}]: "
    local full_message_suffix=""

    # Append exit code context for errors if provided and non-zero
    if [[ "$log_level" == "ERROR" && -n "$exit_code" ]] && (( exit_code != 0 )); then
        # Append color codes carefully around the exit code part
        full_message_suffix=" (${BOLD}Exit Code ${exit_code}${END}${color_code})${END}"
    fi

    # Determine output stream (stderr for WARN/ERROR)
    local output_stream="/dev/stderr"
    if [[ "$log_level" == "INFO" ]]; then
        output_stream="/dev/stdout"
    fi

    # Print using printf with %s for the message to handle special characters safely
    # Structure: ColorStart Prefix Message Suffix ColorEnd Newline
    printf "%s%s%s%s%s\n" "${full_message_prefix}" "${color_code}" "$message" "${full_message_suffix}" "${END}" > "$output_stream"
}

# --- Public API Functions ---

function log_info() {
    _print_log "INFO" "${GREEN}" "$1"
}

# Accepts an optional second argument for context (e.g., an exit code).
# Returns EXIT_SUCCESS (warnings don't indicate function failure).
function log_warn() {
    local message="$1"
    local exit_code="${2:-}" # Optional context code
    _print_log "WARN" "${ORANGE}" "$message" "$exit_code"
    return $EXIT_SUCCESS
}


# Does NOT exit the script.
# The caller should check the return status of functions using log_error.
function log_error() {
    local message="$1"
    local exit_code="${2:-$EXIT_FAILURE}" # defaults to EXIT_FAILURE
    local caller_frame_offset="${3:-}" # Default to empty, _print_log handles the default logic
    _print_log "ERROR" "${RED}" "$message" "$exit_code" "$caller_frame_offset"
    # Indicate that an error occurred via return status, but don't exit.
    if [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        return "$exit_code"
    else
        return $EXIT_FAILURE # Default failure code if provided one was non-numeric
    fi
}

function check_command() {
    local cmd="$1"
    if [[ -z "$cmd" ]]; then
        log_error "Usage: check_command <cmd>"
        return $EXIT_FAILURE
    fi

    if command -v "$cmd" &> /dev/null; then
        return $EXIT_SUCCESS
    else
        return $EXIT_FAILURE
    fi
}

# Usage: check_commands_available "cmd1" "cmd2" ...
function check_commands_available() {
    local -a commands_to_check=("$@")
    if (( ${#commands_to_check[@]} == 0 )); then
        log_warn "No commands provided to check_commands_available."
        return $EXIT_SUCCESS # Nothing to check
    fi

    local all_available=true
    local -a unavailable_commands=()
    local cmd

    for cmd in "${commands_to_check[@]}"; do
        if ! check_command "$cmd"; then
            all_available=false
            unavailable_commands+=("'$cmd'")
        fi
    done

    if "$all_available"; then
        return $EXIT_SUCCESS
    else
        local unavailable_list
        unavailable_list=$(printf "%s, " "${unavailable_commands[@]}")
        unavailable_list=${unavailable_list%, } # Remove trailing comma and space
        log_error "The following required commands are not available: ${unavailable_list}" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi
}

function find_repo_root() {
    local start_dir="${1:-$PWD}"
    local current_dir

    # Resolve potential ~ and relative paths to absolute, physical path (-P)
    # Use '--' to handle start_dir potentially starting with '-'
    if ! current_dir=$(cd -- "$start_dir" &>/dev/null && pwd -P); then
        log_error "Invalid or inaccessible starting directory: '$start_dir'" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    # Search upwards for .repo directory, stopping at root '/'
    while [[ "$current_dir" != "/" && ! -d "${current_dir}/.repo" ]]; do
        current_dir=$(dirname -- "$current_dir")
    done

    # Check if found (must have .repo and not be the filesystem root itself)
    if [[ -d "${current_dir}/.repo" && "$current_dir" != "/" ]]; then
        printf "%s\n" "$current_dir" # Print the found path to stdout
        return $EXIT_SUCCESS
    fi

    log_warn "No .repo directory found in or above: '$start_dir'" $EXIT_FAILURE
    return $EXIT_FAILURE
}

function go_to_repo_root() {
    local start_dir="${1:-$PWD}"
    local repo_root
    local cd_status

    log_info "Attempting to find repo root from '${start_dir}'"

    # Call find_repo_root, capture its output (the path) and exit status
    # Use process substitution or command substitution carefully
    if ! repo_root=$(find_repo_root "$start_dir"); then
        log_error "Failed to find repo root directory. Cannot change directory." $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    if [[ -z "$repo_root" ]]; then
        # Should not happen if find_repo_root returns EXIT_SUCCESS, but good safety check
        log_error "find_repo_root succeeded but returned an empty path. Cannot change directory." $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    if [[ $(pwd) == "$repo_root" ]]; then
        log_info "The current directory is already the repo root: $PWD"
    else
        # Only log and change directory if we are not already in the repo root
        log_info "Repo root found: '${repo_root}'. Changing directory..."

        cd -- "$repo_root" &>/dev/null
        cd_status=$?
        if (( cd_status != 0 )); then
            log_error "Failed to change directory to: '${repo_root}'" "$cd_status"
            return "$cd_status"
        fi
        log_info "Successfully changed directory to repo root: $PWD"
        return $EXIT_SUCCESS
    fi
}

function is_in_repo_workspace() {
    local check_path="${1:-$PWD}"
    local resolved_path

    if ! resolved_path=$(cd -- "$check_path" &>/dev/null && pwd -P); then
        log_error "Invalid or inaccessible directory for repo check: '$check_path'" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    # Run 'repo list' in a subshell to avoid affecting the main script's directory
    # and to capture stderr in case of repo tool issues. Redirect stdout to /dev/null.
    local repo_output repo_status
    repo_output=$( (cd -- "$resolved_path" && repo list) 2>&1 >/dev/null )
    repo_status=$?

    if (( repo_status != 0 )); then
        # Log detailed warning including repo command output for debugging
        log_warn "'repo list' command failed (exit code $repo_status) in '$resolved_path'. Not a repo workspace or repo tool issue? Output: ${repo_output}" "$repo_status"
    fi
    return $repo_status
}

function is_repo_root_dir() {
    local root_path="$1"
    local resolved_path

    if [[ -z "$root_path" ]]; then
        log_error "Usage: is_repo_root_dir <path>" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    # Resolve path robustly first
    if ! resolved_path=$(cd -- "$root_path" &>/dev/null && pwd -P); then
        # Log as warning because non-existence isn't strictly an error in logic, just a state.
        log_warn "Directory does not exist or is inaccessible: '$root_path'" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    if [[ ! -d "${resolved_path}/.repo" ]]; then
        log_warn "Directory exists but is missing '.repo' subdirectory: '${resolved_path}'" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    if is_in_repo_workspace "$resolved_path"; then
        # Both .repo exists and 'repo list' works
        log_info "Confirmed valid repo root directory: '$resolved_path'"
        return $EXIT_SUCCESS
    else
        log_error "Directory '${resolved_path}' contains '.repo' but 'repo list' failed. May be an incomplete or corrupted checkout." $EXIT_FAILURE
        return $EXIT_FAILURE
    fi
}

function is_platform_repo() {
    local repo_path="$1"
    local resolved_path

    if [[ -z "$repo_path" ]]; then
        log_error "Usage: is_platform_repo <path>" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    if ! is_repo_root_dir "$repo_path"; then
        log_error "'$repo_path' is not a valid repo root directory." $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    resolved_path=$(cd -- "$repo_path" &>/dev/null && pwd -P) # Should succeed if is_repo_root_dir passed
    local output repo_status
    # Run in a subshell to cd safely and capture output/errors
    output=$( (cd -- "$resolved_path" && repo list -p) 2>&1 )
    repo_status=$?

    if (( repo_status != 0 )); then
        log_error "'repo list -p' failed in '${resolved_path}' (Exit Code $repo_status):$(printf '\n%s' "$output")" "$repo_status"
        return $EXIT_FAILURE
    fi

    # --- Heuristic Check ---
    # This check assumes common Android platform structure.
    # It might need adjustment if the platform layout changes significantly.
    log_info "Applying heuristic check based on 'repo list -p' output..."
    if [[ "$output" != *"build/make"* && "$output" != *"build/soong"* ]]; then
        log_warn "Directory '${resolved_path}' may not be an Android Platform repository (heuristic check failed: missing 'build/make' or 'build/soong' in 'repo list -p' output)." $EXIT_FAILURE
        return $EXIT_FAILURE
    fi
    # --- End Heuristic Check ---

    log_info "Confirmed Android Platform repository (based on heuristic): ${resolved_path}"
    return $EXIT_SUCCESS
}

function set_platform_repo() {
    local product="$1"
    local device_variant="$2" # e.g., "userdebug"
    local platform_root="$3"
    local lunch_target="${4:-}" # defaults to empty
    local resolved_root
    local envsetup_script

    # Validate arguments
    if [[ -z "$product" || -z "$device_variant" || -z "$platform_root" ]]; then
        log_error "Usage: set_platform_repo <product> <variant> <platform_root>" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    # Validate platform_root is a usable platform repo directory
    # This also resolves the path internally via is_repo_root_dir
    if ! is_platform_repo "$platform_root"; then
        # is_platform_repo already logs details
        log_error "Validation failed for platform root: '$platform_root'" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    # Get the resolved absolute path (already validated)
    resolved_root=$(cd -- "$platform_root" && pwd -P)

    # Check for envsetup.sh existence robustly
    envsetup_script="${resolved_root}/build/envsetup.sh"
    if [[ ! -f "$envsetup_script" ]]; then
        log_error "Cannot find build/envsetup.sh in specified platform root: '${resolved_root}'" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    if [[ -z "$lunch_target" ]]; then
        if [[ -f "${resolved_root}/build/release/release_configs/trunk_staging.textproto" ]]; then
            lunch_target="${product}-trunk_staging-${device_variant}"
        else
            lunch_target="${product}-${device_variant}"
        fi
        log_info "Determined lunch target: ${BOLD}${lunch_target}${END}"
    fi

    if [[ "$PWD" != "$resolved_root" ]]; then
        # Temporarily change to the repo root to run the commands
        # Use pushd/popd to manage directory changes reliably
        log_info "Changing directory to '${resolved_root}' for setup..."

        pushd "$resolved_root" &> /dev/null || { log_error "Failed to pushd into platform root: '${resolved_root}'"; return $EXIT_FAILURE; }

        log_info "Changed directory to '${resolved_root}' successfully."
    fi

    # Source the setup script. This executes it in the CURRENT shell.
    env_cmd=("." "${envsetup_script}")
    log_info "Sourcing Script: ${env_cmd[*]}..."
    run_command "${env_cmd[@]}"
    local source_status=$?
    if (( source_status != 0 )); then
        log_error "Sourcing ${envsetup_script} failed." "$source_status"
        popd > /dev/null || { log_error "'popd' failed after sourcing."; return $EXIT_FAILURE; }
        return "$source_status"
    fi

    log_info "Sourced envsetup.sh successfully."

    # Run the lunch command (should be defined after sourcing envsetup.sh).
    if ! check_command "lunch"; then
        log_error "'lunch' command not found after sourcing envsetup.sh. Setup failed." $EXIT_FAILURE
        popd > /dev/null || { log_error "'popd' failed after checking command."; return $EXIT_FAILURE; }
        return $EXIT_FAILURE
    fi

    log_info "Running: ${BOLD}lunch ${lunch_target}${END}"

    local lunch_output
    local temp_file
    temp_file=$(mktemp)
    lunch "${lunch_target}" 1>"$temp_file" 2>&1
    local lunch_status=$?
    lunch_output=$(cat "$temp_file")
    # Clean up the temporary file
    rm "$temp_file"

    if [[ "$lunch_output" != *"error:"* ]]; then
        log_info "Build environment successfully set for ${lunch_target}."
    else
        log_error "'lunch ${lunch_target}' failed. Output:$(printf '\n%s' "$lunch_output")" "$lunch_status"
        popd > /dev/null || { log_error "'popd' failed after lunching target."; return $EXIT_FAILURE; }
        return "$lunch_status"
    fi

    popd > /dev/null || log_warn "'popd' failed after successful setup. Current directory: $PWD"

    log_info "Setup complete. Returned to original directory via popd."
    return $EXIT_SUCCESS
}

# Function to create softlink
function create_soft_link() {
    if [[ $# -ne 2 ]]; then
        log_error "Usage: create_soft_link <file_name> <soft_link_target>"
        return $EXIT_FAILURE
    fi
    local file_name="$1"
    local soft_link_name="$2"
    local files=()

    # Enable nullglob so that patterns that don't match any files expand to nothing.
    shopt -s nullglob
    # Expand the pattern and populate the 'files' array.
    for f in ${file_name}; do
        files+=("$f")
    done
    # Disable nullglob
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "create_soft_link: No files matched by pattern: '${file_name}'"
        return $EXIT_FAILURE
    fi

    for original_file in "${files[@]}"; do
        local current_soft_link_name
        if [[ "$soft_link_name" ==  *"*"* ]]; then
            local dir_path=$(dirname "$soft_link_name")
            local file_name=$(basename "${original_file}")
            current_soft_link_name="${dir_path}/${file_name}"
        else
            current_soft_link_name="$soft_link_name"
        fi
        if ! ln -s "${original_file}" "${current_soft_link_name}"; then
            local ln_exit_code=$?
            log_error "Failed to create soft link from '${original_file}' to '${current_soft_link_name}'. \
ln exited with code ${ln_exit_code}"
            return $EXIT_FAILURE # Exit the function on the first failure.
        fi
        log_info "Successfully created soft link '${current_soft_link_name}' -> '${original_file}'"
    done
    return $EXIT_SUCCESS
}

# Function to convert/normalize an 'ab://' string
function convert_ab_string() {
    local original_ab_string="$1"
    local __result_var="$2"  # The name of the variable to hold the output
    local ab_string_format="ab://<branch>/<build_target>/<build_id> or ab://<branch>/<build_target>/<build_id>/<file_name>"
    local ab_string_error_message="Invalid build string: '$original_ab_string'. Needs to be: $ab_string_format"

    if [[ "$original_ab_string" != ab://* ]]; then
        log_error "$ab_string_error_message"
        return $EXIT_FAILURE
    fi

    local path_string="${original_ab_string#ab://}"
    IFS='/' read -ra array <<< "$path_string"
    # The expected array length is 3 (branch/target/id) or 4 (branch/target/id/file)
    local array_len="${#array[@]}"
    if (( array_len < 3 || array_len > 4 )); then
        log_error "$ab_string_error_message"
        return $EXIT_FAILURE
    fi

    local branch="${array[0]}"
    local build_target="${array[1]}"
    local build_id=""
    local rest_string=""
    if (( array_len == 3 )); then
        build_id="${array[2]}"
        if [[ -z "$build_id" ]]; then
            build_id="latest"
        fi
    elif (( array_len == 4 )); then
        build_id="${array[2]}"
        rest_string="/${array[3]}"
    fi

    if [[ "$build_id" == "latest" || "$build_id" == "lkgb" ]]; then
        if [[ -f "$DEFAULT_BUILD_CHECKER" ]]; then
            local output
            local check_build_cmd="$DEFAULT_BUILD_CHECKER lkgb --branch $branch --target $build_target"
            output=$("$DEFAULT_BUILD_CHECKER" lkgb --branch "$branch" --target "$build_target")
            if [[ "$output" != *"$branch"* ]]; then
                log_error "Command $DEFAULT_BUILD_CHECKER lkgb --branch $branch --target $build_target \
returned: '$output'. Build target $branch/$build_target doesn't exist in go/ab"
                return $EXIT_FAILURE
            fi
            build_id=$(echo "$output" | awk '{print $3}')
        fi
    fi

    local final_string="ab://$branch/$build_target/$build_id$rest_string"
    if [[ "$original_ab_string" != "$final_string" ]]; then
        log_info "Input: $original_ab_string -> Converted: $final_string"
    fi
    printf -v "$__result_var" "%s" "$final_string"
    return $EXIT_SUCCESS
}

function parse_ab_url() {
    local url="$1"
    local branch_var="$2"
    local target_var="$3"
    local id_var="$4"

    if [[ "$url" != ab://* ]]; then
        log_error "Invalid ab URL format: $url" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    local path_part="${url#ab://}"
    local -a parts=()
    local IFS='/'
    read -r -a parts <<< "$path_part"

    if (( ${#parts[@]} < 2 )); then # Must have at least branch and target
        log_error "Malformed ab URL (not enough parts): $url" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    if [[ -z "${parts[0]}" ]]; then
        log_error "branch variable has no value, check url format: $url" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi

    if [[ -z "${parts[1]}" ]]; then
        log_error "target variable has no value, check url format: $url" $EXIT_FAILURE
        return $EXIT_FAILURE
    fi
    printf -v "$branch_var" "%s" "${parts[0]}"
    printf -v "$target_var" "%s" "${parts[1]}"

    if (( ${#parts[@]} >= 3 )) && [[ -n "${parts[2]}" ]]; then
        printf -v "$id_var" "%s" "${parts[2]}"
    else
        log_warn "id variable is empty, use 'latest' as default id"
        printf -v "$id_var" "%s" "latest"
    fi
    return $EXIT_SUCCESS
}

function query_latest_build_id() {
    local branch="$1"
    local build_target="$2"

    local file_path="${DOWNLOAD_PATH}/${branch}/${build_target}/latest"
    local build_info="${file_path}/BUILD_INFO"

    local fetch_cmd="fetch_artifact"
    if ! command -v fetch_artifact &> /dev/null; then
        if [[ -f "$DEFAULT_FETCH_ARTIFACT" ]]; then
            fetch_cmd="$DEFAULT_FETCH_ARTIFACT"
        else
            log_error "fetch_artifact binary not found. Cannot query latest build ID."
            return $EXIT_FAILURE
        fi
    fi

    mkdir -p "$file_path"
    if [[ -f "$build_info" ]]; then
        rm -f "$build_info"
    fi
    (
        cd "$file_path" || exit $EXIT_FAILURE
        "$fetch_cmd" --branch "$branch" --target "$build_target" --latest 'BUILD_INFO' > /dev/null 2>&1
    )
    local fetch_status=$?
    if (( fetch_status != 0 )) || [[ ! -f "$build_info" ]]; then
        log_error "Failed to fetch the latest BUILD_INFO from ab://${branch}/${build_target}/latest"
        return $EXIT_FAILURE
    fi

    local build_id
    build_id=$(grep -oP '"bid":\s*"\K[^"]+' "${build_info}")
    if [[ -z "$build_id" ]]; then
        log_error "Failed to parse 'bid' from ${build_info}"
        return $EXIT_FAILURE
    fi

    printf "%s" "$build_id"
    return $EXIT_SUCCESS
}


function run_command() {
    local -a command_to_run=("$@")
    local status_code

    # log_info "Running: '${command_to_run[*]}'"

    "${command_to_run[@]}"
    status_code=$?
    if (( status_code == 0 )); then
        log_info "Succeeded."
    else
        log_error "Failed." "$status_code"
    fi

    return $status_code
}

function common_lib::validate_manifest_build_type() {
    local build_type="$1"
    local manifest_file="$2"

    if [[ ! -f "$manifest_file" ]]; then
        log_error "Manifest file not found: $manifest_file"
        return $EXIT_FAILURE
    fi

    local manifest_content
    manifest_content=$(<"$manifest_file")

    if [[ "$build_type" == "pb" || "$build_type" == "sb" ]]; then
        if [[ "$manifest_content" != *"platform/system/core"* && "$manifest_content" != *"gs-pixel"* ]]; then
            log_error "Manifest does not appear to be a Platform/GSI manifest (missing platform/system/core or gs-pixel)."
            return $EXIT_FAILURE
        fi
    elif [[ "$build_type" == "kb" ]]; then
        if [[ "$manifest_content" != *"kernel/common"* ]]; then
            log_error "Manifest does not appear to be a Kernel manifest (missing kernel/common)."
            return $EXIT_FAILURE
        fi
    elif [[ "$build_type" == "vkb" ]]; then
        if [[ "$manifest_content" != *"private/google-modules/soc"* ]]; then
            log_error "Manifest does not appear to be a Vendor Kernel manifest (missing private/google-modules/soc)."
            return $EXIT_FAILURE
        fi
    else
        log_warn "Unknown build_type '$build_type'. Skipping strict manifest validation."
    fi

    return $EXIT_SUCCESS
}

function common_lib::fetch_manifest() {
    local __fm_build_type="$1"
    local __fm_ab_url="$2"
    local __fm_out_ref="$3"

    local __fm_ab_pattern="^ab://([^/]+)/([^/]+)/([0-9]+)$"
    if [[ ! "$__fm_ab_url" =~ $__fm_ab_pattern ]]; then
        log_error "Invalid --sync-manifest URL format: $__fm_ab_url. Expected: ab://<branch>/<target>/<build_id>"
        return $EXIT_FAILURE
    fi

    local __fm_branch="${BASH_REMATCH[1]}"
    local __fm_target="${BASH_REMATCH[2]}"
    local __fm_build_id="${BASH_REMATCH[3]}"
    local __fm_manifest_filename="manifest_${__fm_build_id}.xml"

    local __fm_download_dir="$DOWNLOAD_PATH/$__fm_branch/$__fm_target/$__fm_build_id"
    if [[ ! -d "$__fm_download_dir" ]]; then
        mkdir -p "$__fm_download_dir"
    fi

    local __fm_cache_file="$__fm_download_dir/$__fm_manifest_filename"

    if [[ ! -f "$__fm_cache_file" ]]; then
        log_info "Fetching $__fm_manifest_filename from ab://${__fm_branch}/${__fm_target}/${__fm_build_id}..."
        pushd "$__fm_download_dir" > /dev/null || return $EXIT_FAILURE
        "$DEFAULT_FETCH_ARTIFACT" --branch "${__fm_branch}" --target "${__fm_target}" --bid "${__fm_build_id}" "${__fm_manifest_filename}"
        local __fm_fetch_exit_code=$?
        popd > /dev/null || return $EXIT_FAILURE

        if (( __fm_fetch_exit_code != 0 )); then
            log_error "Failed to fetch manifest for $__fm_ab_url"
            return $EXIT_FAILURE
        fi
    else
        log_info "Using cached manifest $__fm_cache_file"
    fi

    if [[ ! -f "$__fm_cache_file" ]]; then
        log_error "Manifest not found at expected path: $__fm_cache_file"
        return $EXIT_FAILURE
    fi

    if ! common_lib::validate_manifest_build_type "$__fm_build_type" "$__fm_cache_file"; then
        log_error "Manifest validation failed for $__fm_ab_url"
        return $EXIT_FAILURE
    fi

    if [[ -n "$__fm_out_ref" ]]; then
        printf -v "$__fm_out_ref" "%s" "$__fm_cache_file"
    fi

    return $EXIT_SUCCESS
}

function set_env_var() {
    local var_name="$1"
    local var_value="$2"

    # Validate variable name (POSIX-compliant)
    if ! [[ "$var_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid environment variable name '$var_name'"
        return $EXIT_FAILURE
    fi

    export "$var_name=$var_value"
    log_info "Exported environment variable: ${var_name}='${var_value}'"
    return $EXIT_SUCCESS
}
function common_lib::enter_interactive_fix_mode() {
    local prompt_message="$1"
    local non_interactive_flag="${2:-false}"

    if [[ "$non_interactive_flag" == "true" ]]; then
        log_error "${prompt_message} Failed in non-interactive mode."
        # Return 5, which maps to "bad"
        return 5
    fi

    local rv=5 # Default to 'bad'
    cat <<-EOF2 1>&2
    ${YELLOW}${prompt_message}${END}
    Spawning a new shell.
    You can attempt to fix the issue (e.g., resolve merge conflicts).
    Once done, exit this shell with one of the following codes:
      ${GREEN}exit 0${END}:     Retry the operation. If successful, bisection continues.
      ${ORANGE}exit 125${END}:   '${BOLD}Skip${END}${YELLOW}' this commit (mark as untestable).
      ${RED}exit 1-124${END}:   Mark this commit as '${BOLD}bad${END}${YELLOW}' (e.g., exit 1 or exit 5).
      ${RED}exit 128-255${END}:  '${BOLD}Abort${END}${YELLOW}' the entire bisection process immediately.
EOF2
    bash -i
    rv=$?
    return "${rv}"
}

function common_lib::sync_tree_to_manifest() {
    local tree_path="$1"
    local manifest_filename="$2"
    local type_code="${3:-repo}"

    log_info "[$type_code] Syncing tree '$tree_path' to $manifest_filename..."
    pushd "$tree_path" > /dev/null || {
        log_error "[$type_code] Failed to cd into $tree_path"
        return $EXIT_FAILURE
    }

    repo init -m "$manifest_filename" || {
        log_error "[$type_code] repo init failed for $manifest_filename"
        popd > /dev/null
        return $EXIT_FAILURE
    }

    repo sync -c -j"$(nproc)" || {
        log_error "[$type_code] repo sync failed for $manifest_filename"
        popd > /dev/null
        return $EXIT_FAILURE
    }

    popd > /dev/null
    return $EXIT_SUCCESS
}

function common_lib::parse_artifact_url() {
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
            log_error "Build string is not a valid 'ab://' URL or a local directory: $build_str"
            return $EXIT_FAILURE
        fi
    fi

    local path_part="${build_str#ab://}"
    local -a parts=()
    local IFS='/'
    read -r -a parts <<< "$path_part"

    if (( ${#parts[@]} < 3 )); then
        log_error "Malformed ab URL. Expected at least 3 parts: ab://<branch>/<target>/<ids>[/<filename>]. Got: ${build_str}"
        return $EXIT_FAILURE
    fi

    if [[ -z "${parts[0]}" || -z "${parts[1]}" || -z "${parts[2]}" ]]; then
        log_error "The branch, target, or ids cannot be empty string. Got: ${build_str}"
        return $EXIT_FAILURE
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
                log_error "Invalid build ID in list. All IDs must be numeric: $id"
                return $EXIT_FAILURE
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
            log_error "Invalid range format. IDs must be numeric: $id_part"
            return $EXIT_FAILURE
        fi
        if (( id1 >= id2 )); then
            log_error "Invalid range: start ID ($id1) must be less than end ID ($id2)."
            return $EXIT_FAILURE
        fi
        ids_ref=("$id1" "$id2")
    else
        type_ref="single"
        # A single ID can be numeric or "latest"
        if ! [[ "$id_part" =~ ^[0-9]+$ || "$id_part" == "latest" ]]; then
            log_error "Invalid build ID. Must be numeric or 'latest': $id_part"
            return $EXIT_FAILURE
        fi
        ids_ref=("$id_part")
    fi
    return $EXIT_SUCCESS
}
