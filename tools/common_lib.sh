#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# Common Script Library for kernel test tools

# --- Include Guard ---
# Prevents the library from being sourced multiple times.
if [[ -n "$__COMMON_LIB_SOURCED__" ]]; then
    return 0
fi
readonly __COMMON_LIB_SOURCED__=1

# --- Constants ---
readonly FETCH_SCRIPT="kernel/tests/tools/fetch_artifact.sh"
readonly KERNEL_JDK_PATH="prebuilts/jdk/jdk11/linux-x86"
readonly LOCAL_JDK_PATH="/usr/local/buildtools/java/jdk11"
readonly PLATFORM_JDK_PATH="prebuilts/jdk/jdk21/linux-x86"

# --- BinFS ---
readonly CL_FLASH_CLI=/google/bin/releases/android/flashstation/cl_flashstation
readonly LOCAL_FLASH_CLI=/google/bin/releases/android/flashstation/local_flashstation


# --- Internal State Flags ---
__COMMON_LIB_NO_TPUT__="" # Flag set if tput is unavailable

# --- Dependency Checks ---
if ! command -v tput &> /dev/null; then
    echo "[WARN] common_lib.sh: Command 'tput' not found. Colored output disabled." >&2
    __COMMON_LIB_NO_TPUT__=1
fi

if ! command -v repo &> /dev/null; then
    echo "[ERROR] common_lib.sh: Required command 'repo' not found. This library needs 'repo'." >&2
    return 1
fi

if ! command -v date &> /dev/null; then
    echo "[ERROR] common_lib.sh: Required command 'date' not found. Timestamping will fail." >&2
    return 1
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
    # Try ISO 8601 format with nanoseconds if supported
    if ts=$(date --iso-8601=ns 2>/dev/null); then
        printf "%s" "$ts"
        return 0
    # Fallback to seconds
    elif ts=$(date --iso-8601=seconds 2>/dev/null); then
        printf "%s" "$ts"
        return 0
    # Fallback to high-precision format if ISO fails but N supported
    elif ts=$(date '+%Y-%m-%d %H:%M:%S.%N' 2>/dev/null); then
        printf "%s" "$ts"
        return 0
    elif ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null); then
        printf "%s" "$ts"
        return 0
    else
        # If date command fails entirely
        printf "TIMESTAMP_ERR" >&2 # Avoid calling log_error to prevent recursion
        return 1
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
        context_info="[$caller_file:$caller_line ($caller_function)]"
    else
        context_info="[${caller_info}]" # Fallback if parsing fails
    fi

    # Format: TIMESTAMP LEVEL [script:line (function)]: Message
    local log_prefix="${timestamp} ${log_level}"
    local full_message_prefix="${log_prefix} ${context_info}: "
    local full_message_suffix=""

    # Append exit code context for errors if provided and non-zero
    if [[ "$log_level" == "ERROR" && -n "$exit_code" && "$exit_code" -ne 0 ]]; then
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
    printf "%s%s%s%s%s\n" "${color_code}" "${full_message_prefix}" "$message" "${full_message_suffix}" "${END}" > "$output_stream"
}

# --- Public API Functions ---

function log_info() {
    _print_log "INFO" "${GREEN}" "$1"
}

# Accepts an optional second argument for context (e.g., an exit code).
# Returns 0 (warnings don't indicate function failure).
function log_warn() {
    local message="$1"
    local exit_code="${2:-}" # Optional context code
    _print_log "WARN" "${YELLOW}" "$message" "$exit_code"
    return 0
}


# Does NOT exit the script.
# The caller should check the return status of functions using log_error.
function log_error() {
    local message="$1"
    local exit_code="${2:-1}" # defaults to 1
    local caller_frame_offset="${3:-}" # Default to empty, _print_log handles the default logic
    _print_log "ERROR" "${RED}" "$message" "$exit_code" "$caller_frame_offset"
    # Indicate that an error occurred via return status, but don't exit.
    if [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        return "$exit_code"
    else
        return 1 # Default failure code if provided one was non-numeric
    fi
}

function check_command() {
    local cmd="$1"
    if [[ -z "$cmd" ]]; then
        log_error "Usage: check_command <cmd>"
        return 1
    fi

    if command -v "$cmd" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Usage: check_commands_available "cmd1" "cmd2" ...
function check_commands_available() {
    local -a commands_to_check=("$@")
    if [[ ${#commands_to_check[@]} -eq 0 ]]; then
        log_warn "No commands provided to check_commands_available."
        return 0 # Nothing to check
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
        return 0
    else
        local unavailable_list
        unavailable_list=$(printf "%s, " "${unavailable_commands[@]}")
        unavailable_list=${unavailable_list%, } # Remove trailing comma and space
        log_error "The following required commands are not available: ${unavailable_list}" 1
        return 1
    fi
}

function find_repo_root() {
    local start_dir="${1:-$PWD}"
    local current_dir

    # Resolve potential ~ and relative paths to absolute, physical path (-P)
    # Use '--' to handle start_dir potentially starting with '-'
    if ! current_dir=$(cd -- "$start_dir" &>/dev/null && pwd -P); then
        log_error "Invalid or inaccessible starting directory: '$start_dir'" 1
        return 1
    fi

    # Search upwards for .repo directory, stopping at root '/'
    while [[ "$current_dir" != "/" && ! -d "${current_dir}/.repo" ]]; do
        current_dir=$(dirname -- "$current_dir")
    done

    # Check if found (must have .repo and not be the filesystem root itself)
    if [[ -d "${current_dir}/.repo" && "$current_dir" != "/" ]]; then
        printf "%s\n" "$current_dir" # Print the found path to stdout
        return 0
    fi

    log_warn "No .repo directory found in or above: '$start_dir'" 1
    return 1
}

function go_to_repo_root() {
    local start_dir="${1:-$PWD}"
    local repo_root
    local cd_status

    log_info "Attempting to find repo root starting from: '${start_dir}'"

    # Call find_repo_root, capture its output (the path) and exit status
    # Use process substitution or command substitution carefully
    if ! repo_root=$(find_repo_root "$start_dir"); then
        log_error "Failed to find repo root directory. Cannot change directory." 1
        return 1
    fi

    if [[ -z "$repo_root" ]]; then
        # Should not happen if find_repo_root returns 0, but good safety check
        log_error "find_repo_root succeeded but returned an empty path. Cannot change directory." 1
        return 1
    fi

    log_info "Repo root found: '${repo_root}'. Changing directory..."

    cd -- "$repo_root" &>/dev/null
    cd_status=$?
    if (( cd_status != 0 )); then
        log_error "Failed to change directory to: '${repo_root}'" "$cd_status"
        return "$cd_status"
    fi

    log_info "Successfully changed directory to repo root: $PWD"
    return 0
}

function is_in_repo_workspace() {
    local check_path="${1:-$PWD}"
    local resolved_path

    if ! resolved_path=$(cd -- "$check_path" &>/dev/null && pwd -P); then
        log_error "Invalid or inaccessible directory for repo check: '$check_path'" 1
        return 1
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
        log_error "Usage: is_repo_root_dir <path>" 1
        return 1
    fi

    # Resolve path robustly first
    if ! resolved_path=$(cd -- "$root_path" &>/dev/null && pwd -P); then
        # Log as warning because non-existence isn't strictly an error in logic, just a state.
        log_warn "Directory does not exist or is inaccessible: '$root_path'" 1
        return 1
    fi

    if [[ ! -d "${resolved_path}/.repo" ]]; then
        log_warn "Directory exists but is missing '.repo' subdirectory: '${resolved_path}'" 1
        return 1
    fi

    if is_in_repo_workspace "$resolved_path"; then
        # Both .repo exists and 'repo list' works
        log_info "Confirmed valid repo root directory: '$resolved_path'"
        return 0
    else
        log_error "Directory '${resolved_path}' contains '.repo' but 'repo list' failed. May be an incomplete or corrupted checkout." 1
        return 1
    fi
}

function is_platform_repo() {
    local repo_path="$1"
    local resolved_path

    if [[ -z "$repo_path" ]]; then
        log_error "Usage: is_platform_repo <path>" 1
        return 1
    fi

    if ! is_repo_root_dir "$repo_path"; then
        log_error "'$repo_path' is not a valid repo root directory." 1
        return 1
    fi

    resolved_path=$(cd -- "$repo_path" &>/dev/null && pwd -P) # Should succeed if is_repo_root_dir passed
    local output repo_status
    # Run in a subshell to cd safely and capture output/errors
    output=$( (cd -- "$resolved_path" && repo list -p) 2>&1 )
    repo_status=$?

    if (( repo_status != 0 )); then
        log_error "'repo list -p' failed in '${resolved_path}' (Exit Code $repo_status):$(printf '\n%s' "$output")" "$repo_status"
        return 1
    fi

    # --- Heuristic Check ---
    # This check assumes common Android platform structure.
    # It might need adjustment if the platform layout changes significantly.
    log_info "Applying heuristic check based on 'repo list -p' output..."
    if [[ "$output" != *"build/make"* && "$output" != *"build/soong"* ]]; then
        log_warn "Directory '${resolved_path}' may not be an Android Platform repository (heuristic check failed: missing 'build/make' or 'build/soong' in 'repo list -p' output)." 1
        return 1
    fi
    # --- End Heuristic Check ---

    log_info "Confirmed Android Platform repository (based on heuristic): ${resolved_path}"
    return 0
}

function set_platform_repo() {
    local product="$1"
    local device_variant="$2" # e.g., "userdebug"
    local platform_root="$3"
    local resolved_root
    local lunch_target
    local envsetup_script

    # Validate arguments
    if [[ -z "$product" || -z "$device_variant" || -z "$platform_root" ]]; then
        log_error "Usage: set_platform_repo <product> <variant> <platform_root>" 1
        return 1
    fi

    # Validate platform_root is a usable platform repo directory
    # This also resolves the path internally via is_repo_root_dir
    if ! is_platform_repo "$platform_root"; then
        # is_platform_repo already logs details
        log_error "Validation failed for platform root: '$platform_root'" 1
        return 1
    fi

    # Get the resolved absolute path (already validated)
    resolved_root=$(cd -- "$platform_root" && pwd -P)

    # Check for envsetup.sh existence robustly
    envsetup_script="${resolved_root}/build/envsetup.sh"
    if [[ ! -f "$envsetup_script" ]]; then
        log_error "Cannot find build/envsetup.sh in specified platform root: '${resolved_root}'" 1
        return 1
    fi

    if [[ -f "${resolved_root}/build/release/release_configs/trunk_staging.textproto" ]]; then
        lunch_target="${product}-trunk_staging-${device_variant}"
    else
        lunch_target="${product}-${device_variant}"
    fi
    log_info "Determined lunch target: ${BOLD}${lunch_target}${END}"

    # Temporarily change to the repo root to run the commands
    # Use pushd/popd to manage directory changes reliably
    log_info "Changing directory to '${resolved_root}' for setup..."

    pushd "$resolved_root" > /dev/null
    local pushd_status=$?
    if (( pushd_status != 0 )); then
        log_error "Failed to pushd into platform root: '${resolved_root}'" "$pushd_status"
        return "$pushd_status"
    fi

    log_info "Changed directory to '${resolved_root}' successfully."

    # Source the setup script. This executes it in the CURRENT shell.
    env_cmd=("." "${envsetup_script}")
    log_info "Sourcing Script: ${env_cmd[*]}..."
    run_command "${env_cmd[@]}"
    local source_status=$?
    if (( source_status != 0 )); then
        log_error "Sourcing ${envsetup_script} failed." "$source_status"
        popd > /dev/null
        return "$source_status"
    fi

    log_info "Sourced envsetup.sh successfully."

    # Run the lunch command (should be defined after sourcing envsetup.sh).
    if ! check_command "lunch"; then
        log_error "'lunch' command not found after sourcing envsetup.sh. Setup failed." 1
        popd > /dev/null
        return 1
    fi

    log_info "Running: ${BOLD}lunch ${lunch_target}${END}"

    local lunch_output
    local temp_file=$(mktemp)
    lunch "${lunch_target}" 1>"$temp_file" 2>&1
    local lunch_status=$?
    lunch_output=$(cat "$temp_file")
    # Clean up the temporary file
    rm "$temp_file"

    if [[ "$lunch_output" != *"error:"* ]]; then
        log_info "Build environment successfully set for ${lunch_target}."
    else
        log_error "'lunch ${lunch_target}' failed. Output:$(printf '\n%s' "$lunch_output")" "$lunch_status"
        popd > /dev/null
        return "$lunch_status"
    fi

    popd > /dev/null
    local popd_status=$?
    if (( popd_status != 0 )); then
        log_warn "popd failed (Exit Code ${popd_status}) after successful setup. Current directory: $PWD"
    fi

    log_info "Setup complete. Returned to original directory via popd."
    return 0
}

function parse_ab_url() {
    local url="$1"
    local branch_var="$2"
    local target_var="$3"
    local id_var="$4"

    if [[ "$url" != ab://* ]]; then
        log_error "Invalid ab URL format: $url" 1
        return 1
    fi

    local path_part="${url#ab://}"
    local -a parts=()
    local IFS='/'
    read -r -a parts <<< "$path_part"

    if [[ ${#parts[@]} -lt 2 ]]; then # Must have at least branch and target
        log_error "Malformed ab URL (not enough parts): $url" 1
        return 1
    fi

    if [[ -z "${parts[0]}" ]]; then
        log_error "branch variable has no value, check url format: $url" 1
        return 1
    fi

    if [[ -z "${parts[1]}" ]]; then
        log_error "target variable has no value, check url format: $url" 1
        return 1
    fi
    printf -v "$branch_var" "%s" "${parts[0]}"
    printf -v "$target_var" "%s" "${parts[1]}"

    if [[ ${#parts[@]} -ge 3 && -n "${parts[2]}" ]]; then
        printf -v "$id_var" "%s" "${parts[2]}"
    else
        log_warn "id variable is empty, use 'latest' as default id"
        printf -v "$id_var" "%s" "latest"
    fi
    return 0
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

function set_env_var() {
    local var_name="$1"
    local var_value="$2"

    # Validate variable name (POSIX-compliant)
    if ! [[ "$var_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid environment variable name '$var_name'"
        return 1
    fi

    export "$var_name=$var_value"
    log_info "Exported environment variable: ${var_name}='${var_value}'"
    return 0
}

log_info "common_lib.sh sourced successfully."
