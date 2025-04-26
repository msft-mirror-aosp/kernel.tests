#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# Common Script Library for kernel test tools

# Include Guard
if [[ -n "$__COMMON_LIB_SOURCED__" ]]; then
    return 0
fi
__COMMON_LIB_SOURCED__=1

# Constants
CALLER_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[1]}" )" &> /dev/null && pwd )"
CALLER_SCRIPT_NAME=$(basename "${BASH_SOURCE[1]}")
CALLER_SCRIPT_PATH="${CALLER_SCRIPT_DIR}/${CALLER_SCRIPT_NAME}"
FETCH_SCRIPT="kernel/tests/tools/fetch_artifact.sh"
KERNEL_JDK_PATH="prebuilts/jdk/jdk11/linux-x86"
LOCAL_JDK_PATH="/usr/local/buildtools/java/jdk11"
PLATFORM_JDK_PATH="prebuilts/jdk/jdk21/linux-x86"

# Color Constants
BLUE="$(tput setaf 4)"
BOLD="$(tput bold)"
END="$(tput sgr0)"
GREEN="$(tput setaf 2)"
ORANGE="$(tput setaf 208)"
RED="$(tput setaf 198)"
YELLOW="$(tput setaf 3)"

# Internal Use
function _timestamp() {
    date '+%Y-%m-%d %H:%M:%S.%N' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

# Libraries
function check_command() {
    local cmd="$1"
    if command -v "$cmd" &> /dev/null; then
        return 0
    else
        log_error "Command '${cmd}' not found!" $?
        return 1
    fi
}

function go_to_repo_root() {
    local init_dir="$1"
    current_dir=$(eval echo "$init_dir")
    while [ ! -d "${current_dir}/.repo" ] && [ "$current_dir" != "/" ]; do
        current_dir=$(dirname "$current_dir")  # Go up one directory
        cd "$current_dir" || log_error "Failed to cd to $current_dir" $?
    done

    if [ "$current_dir" = "/" ] || [ ! -d "${current_dir}/.repo" ]; then
        log_error "No .repo directory found in or above the current folder ${init_dir}"
    fi
}

function log_info() {
    print_log "INFO" "${GREEN}$1${END}" 0;
}

function log_warn() {
    print_log "WARN" "${YELLOW}$1${END}" 0;
}

function log_error() {
    local message="$1"
    local exit_code="${2:-1}"

    print_log "ERROR" "${RED}${message}${END}" $exit_code

      # --- EXIT SCRIPT ---
    # Terminate the script using the specified or default exit code.
    if [[ "$exit_code" -ne 0 ]]; then
        exit "$exit_code"
    fi
}

function print_log() {
    local log_level="$1"
    local message="$2"
    local exit_code="$3"

    # Get Caller Information
    local caller_funcname="global"
    local caller_source=$(basename "$0")
    local caller_lineno="-"
    for i in "${!FUNCNAME[@]}"; do
        if [[ "${FUNCNAME[$i]}" != "print_log" && "${FUNCNAME[$i]}" != "log_info" && "${FUNCNAME[$i]}" != "print_info" && \
            "${FUNCNAME[$i]}" != "log_warn" && "${FUNCNAME[$i]}" != "print_warn" && \
            "${FUNCNAME[$i]}" != "log_error" && "${FUNCNAME[$i]}" != "print_error" ]]; then
            caller_funcname="${FUNCNAME[$i]}"
            if (( i > 0 )); then
                caller_source=$(basename "${BASH_SOURCE[$((i))]}")
                caller_lineno="${BASH_LINENO[$((i - 1))]}"
            fi
            break
        fi
    done

    # Handle cases where the call might be from the global scope (no function name)
    if [[ "$caller_funcname" == "main" || "$caller_funcname" == "" ]]; then
        caller_funcname="global scope"
    fi

    # Construct the message
    local log_line="\"$caller_source\", line $caller_lineno, in $caller_funcname:\n"
    log_line+="$message"

    # Construct the error message
    if [[ "$log_level" == "ERROR" ]] && [[ "$exit_code" -ne 0 ]]; then
        log_line+=" (Exit Code ${BOLD}$exit_code${END})"
        echo -e "$log_line" >&2
    else
        echo -e "$log_line"
    fi
}

function is_in_repo_workspace() {
    # Only care about the exit status.
    repo list > /dev/null 2>&1
    return $?
}
