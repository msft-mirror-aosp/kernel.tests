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
    log_error "Command '${cmd}' not found!"
    return 1
  fi
}

function log_info() {
    print_log "INFO" "${GREEN}$1${END}";
}

function log_warn() {
    print_log "WARN" "${YELLOW}$1${END}";
}

function log_error() {
    local message="$1"
    local exit_code="${2:-1}"
    local line_no="${3:-}"

    print_log "ERROR" "${RED}${message} ${line_no}${END}";
    cd "$CALLER_SCRIPT_DIR" || echo "Failed to cd to $CALLER_SCRIPT_DIR"
    exit "$exit_code"
}

function print_log() {
    local log_level="$1"
    local message="$2"
    local timestamp
    timestamp=$(_timestamp)

    local caller_script_name="${CALLER_SCRIPT_NAME}"
    local log_line="[$log_level] [$timestamp] [$caller_script_name]: $message"

    if [[ "$log_level" == "ERROR" ]]; then
        echo "$log_line" >&2
    else
        echo "$log_line"
    fi
}
