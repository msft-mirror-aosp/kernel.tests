#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# fetch_artifact .sh is a handy tool dedicated to download artifacts from ci.
# The fetch_artifact binary is needed for this script. Please see more info at:
#    go/fetch_artifact,
#    or
#    https://android.googlesource.com/tools/fetch_artifact/
# Will use x20 binary: /google/data/ro/projects/android/fetch_artifact by default.
# Can install fetch_artifact locally with:
# sudo glinux-add-repo android stable && \
# sudo apt update && \
# sudo apt install android-fetch-artifact#
#
BOLD="$(tput bold)"
END="$(tput sgr0)"
GREEN="$(tput setaf 2)"
RED="$(tput setaf 198)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 34)"

function binary_checker() {
    if which fetch_artifact &> /dev/null; then
        FETCH_CMD="fetch_artifact"
    elif [[ ! -z "${FETCH_ARTIFACT}" && -f "${FETCH_ARTIFACT}" ]]; then
        FETCH_CMD="${FETCH_ARTIFACT}"
    elif [[ -f "$DEFAULT_FETCH_ARTIFACT" ]]; then
        FETCH_CMD="$DEFAULT_FETCH_ARTIFACT"
    else
        log_error "The fetch_artifact is not found. Please run 'gcert' to make sure your workstation \
is certified. Please see go/fetch_artifact or \
https://android.googlesource.com/tools/fetch_artifact/+/refs/heads/main for more information"
        exit 1
    fi
}

# --- Library Import ---
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$( cd "$( dirname "${SCRIPT_PATH}" )" &> /dev/null && pwd -P)"
LIB_PATH="${SCRIPT_DIR}/common_lib.sh"

if [[ ! -f "$LIB_PATH" ]]; then
    # Cannot use log_error yet as library isn't sourced
    echo "FATAL ERROR: Cannot find required library '$LIB_PATH'" >&2
    exit 1
fi

# Source the library. Check return code in case sourcing fails (e.g., missing dependency in lib)
if ! . "$LIB_PATH"; then
    echo "FATAL ERROR: Failed to source library '$LIB_PATH'. Check common_lib.sh dependencies." >&2
    exit 1
fi

binary_checker

fetch_cli="$FETCH_CMD"

BUILD_INFO=
BUILD_FORMAT="ab://<branch>/<build_target>/<build_id>/<file_name>"
EXTRA_OPTIONS=
IGNORE_CACHE=false

MY_NAME="${0##*/}"

for i in "$@"; do
    case $i in
        "ab://"*)
        BUILD_INFO=$i
        ;;
        --ignore-cache)
        IGNORE_CACHE=true
        ;;
        *)
        EXTRA_OPTIONS+=" $i"
        ;;
    esac
done
if [[ -z "$BUILD_INFO" ]]; then
    log_error "$0 didn't come with the expected $BUILD_FORMAT"
fi

IFS='/' read -ra array <<< "$BUILD_INFO"
if (( ${#array[@]} < 6 )); then
    log_error "Invalid build format: $BUILD_INFO. Needs to be: $BUILD_FORMAT"
    exit 1
elif (( ${#array[@]} > 7 )); then
    log_error "Invalid build format: $BUILD_INFO. Needs to be: $BUILD_FORMAT"
    exit 1
fi

branch="${array[2]}"
build_target="${array[3]}"
build_id="${array[4]}"

if [[ "$build_id" == "latest" ]]; then
    log_info "Build ID is 'latest', attempting to resolve numeric ID..."
    resolved_id=$(query_latest_build_id "$branch" "$build_target")
    if [[ $? -eq 0 && -n "$resolved_id" ]]; then
        log_info "Resolved 'latest' to numeric build ID: $resolved_id"
        build_id="$resolved_id"
        array[4]="$resolved_id"
    else
        log_warn "Failed to resolve 'latest' build ID. Falling back to using 'latest'."
    fi
fi

file_path="$DOWNLOAD_PATH/$branch/$build_target/$build_id"
if [[ ! -d "$file_path" ]]; then
    existing_file_name=""
else
    existing_file_name=$(find "$file_path" -maxdepth 1 -type f -name "${array[5]}")
fi
file_name="$file_path/${array[5]}"

if [[ -f "$existing_file_name" ]]; then
    if [[ "$IGNORE_CACHE" == true ]]; then
        log_info "File $existing_file_name exists, but --ignore-cache is set. Removing and re-downloading."
        rm -f "$existing_file_name"
    else
        log_info "Use the existing $existing_file_name. Skipping download."
        exit 0
    fi
fi

if [[ ! -d "$file_path" ]]; then
    mkdir -p "$file_path"
fi
fetch_cli+=" --branch ${array[2]}"
fetch_cli+=" --target ${array[3]}"
if [[ "${array[4]}" != latest* ]]; then
    fetch_cli+=" --bid ${array[4]}"
else
    fetch_cli+=" --latest"
fi
fetch_cli+="$EXTRA_OPTIONS"
fetch_cli+=" '${array[5]}'"
cd "$file_path"  || { log_error "Failed to go to $file_path"; exit 1; }
log_info "Running command: $fetch_cli"
eval "$fetch_cli" 2>/tmp/err.txt
exit_code=$?

if (( exit_code == 0 )); then
    log_info "Downloaded ${array[5]} to $file_path"
    exit 0
elif grep -q "BuildNotFound" /tmp/err.txt; then
    log_error "$BUILD_INFO is not found in the ab build server."
    exit 1
elif grep -q "NoFileFoundError" /tmp/err.txt; then
    log_warn "File '${array[5]}' not found in this build."
    exit 1
elif grep -q "StatusCode.UNAVAILABLE" /tmp/err.txt; then
    log_warn "The build server is not available. Try again"
    sleep 5
    eval "$fetch_cli"
    exit_code=$?
fi

exit $exit_code
