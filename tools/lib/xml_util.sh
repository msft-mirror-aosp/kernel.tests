#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

#
# XML Manipulation Library using xmlstarlet
#
# Usage:
#   source path/to/xml_util.sh
#
#   # Scenario 1: Create a new file
#   xml_util::init "/path/to/new.xml" "bisect"
#
#   # Scenario 2: Load an existing file
#   xml_util::load "/path/to/existing.xml"
#

# --- Include Guard---
if [[ -n "${__XML_UTIL_SOURCED__:-}" ]]; then
    return 0
fi
readonly __XML_UTIL_SOURCED__=1

# --- Dependencies ---
if [[ -z "${__COMMON_LIB_SOURCED__:-}" ]]; then
    _XML_UTIL_SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
    _XML_UTIL_SCRIPT_DIR="$(dirname "${_XML_UTIL_SCRIPT_PATH}")"
    _COMMON_LIB_PATH="${_XML_UTIL_SCRIPT_DIR}/../common_lib.sh"

    if [[ ! -f "$_COMMON_LIB_PATH" ]]; then
        echo "FATAL ERROR (xml_util): Cannot find required library '$_COMMON_LIB_PATH'" >&2
        return 1
    fi

    if ! source "$_COMMON_LIB_PATH"; then
        echo "FATAL ERROR (xml_util): Failed to source library '$_COMMON_LIB_PATH'" >&2
        return 1
    fi
fi

if ! command -v xmlstarlet &> /dev/null; then
    log_error "Required command 'xmlstarlet' not found."
    return 1
fi

# --- Internal State ---
_XML_UTIL_DEFAULT_FILE=""

# --- Public Functions ---
function xml_util::init() {
    local file_path="$1"
    local root_tag="${2:-root}" # Default to "root" if not specified

    if [[ -z "$file_path" ]]; then
        log_error "No file path provided."
        return 1
    fi

    # Check if file already exists -> Error out
    if [[ -f "$file_path" ]]; then
        log_error "File already exists: $file_path. Use xml_util::load to use an existing file."
        return 1
    fi

    local dir_name
    dir_name=$(dirname "$file_path")

    if [[ ! -d "$dir_name" ]]; then
        log_info "Creating directory $dir_name..."
        mkdir -p "$dir_name"
    fi

    log_info "Creating new XML file at $file_path with root tag <$root_tag/>..."

    echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?><${root_tag}/>" > "$file_path"

    # Validate the newly created file
    if ! xmlstarlet val -q "$file_path"; then
        log_error "Internal Error. Failed to create a valid XML file at '$file_path'."
        return 1
    fi

    _XML_UTIL_DEFAULT_FILE="$file_path"
    log_info "XML library context set to new file: ${file_path}"
}

function xml_util::load() {
    local file_path="$1"

    _xml_util::check_file "$file_path" || return 1

    # Validate XML format
    if ! xmlstarlet val -q "$file_path"; then
        log_error "Validation failed. '$file_path' is not a valid XML file."
        return 1
    fi

    _XML_UTIL_DEFAULT_FILE="$file_path"
    log_info "XML library context loaded from: ${file_path}"
}

function _xml_util::check_file() {
    local file="$1"
    if [[ -z "$file" ]]; then
        log_error "XML operation failed: No XML file specified (and no default set via xml_util::load/xml_util::init)."
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        log_error "XML operation failed: File not found: $file"
        return 1
    fi
    return 0
}

function xml_util::read_value() {
    local xpath="$1"
    local file="${2:-$_XML_UTIL_DEFAULT_FILE}"

    _xml_util::check_file "$file" || return 1

    xmlstarlet sel -t -v "$xpath" "$file" 2>/dev/null
}

function xml_util::read_values_to_array() {
    local xpath="$1"
    local -n _dest_array_ref="$2"
    local file="${3:-$_XML_UTIL_DEFAULT_FILE}"

    _xml_util::check_file "$file" || return 1

    mapfile -t _dest_array_ref < <(xmlstarlet sel -t -v "$xpath" -n "$file" 2>/dev/null)
}

function xml_util::read_attributes_to_array() {
    local xpath="$1"
    local -n _dest_array_ref="$2"
    local file="${3:-$_XML_UTIL_DEFAULT_FILE}"

    if [[ "$xpath" != *"@"* ]]; then
        log_error "Invalid XPath '$xpath'. Attribute XPath must contain '@'."
        return 1
    fi

    _xml_util::check_file "$file" || return 1

    mapfile -t _dest_array_ref < <(xmlstarlet sel -t -v "$xpath" -n "$file" 2>/dev/null)
}

function xml_util::update_xml_node() {
    local xpath_expr="$1"
    local value="$2"
    local file="${3:-$_XML_UTIL_DEFAULT_FILE}"

    _xml_util::check_file "$file" || return 1

    log_info "Updating XML node in $(basename "$file"): $xpath_expr -> $value"
    xmlstarlet ed -L -u "$xpath_expr" -v "$value" "$file"
}

function xml_util::update_xml_attribute() {
    local xpath_expr="$1"
    local attr_name="$2"
    local value="$3"
    local file="${4:-$_XML_UTIL_DEFAULT_FILE}"

    _xml_util::check_file "$file" || return 1

    log_info "Updating XML attribute in $(basename "$file"): $xpath_expr @$attr_name -> $value"
    # Delete the attribute first to avoid errors if it doesn't exist, then insert it.
    xmlstarlet ed -L \
        -d "${xpath_expr}/@${attr_name}" \
        -i "$xpath_expr" -t "attr" -n "$attr_name" -v "$value" \
        "$file"
}

# --- Construction Helpers (Command Builders) ---
# These functions append arguments to a command array for efficient batch editing.
# They do not perform file I/O directly.
function xml_util::add_node() {
    local -n _cmd_array_ref="$1"
    local parent_xpath="$2"
    local element_name="$3"
    _cmd_array_ref+=(-s "$parent_xpath" -t elem -n "$element_name")
}

function xml_util::add_attribute() {
    local -n _cmd_array_ref="$1"
    local parent_xpath="$2"
    local attr_name="$3"
    local attr_value="$4"
    _cmd_array_ref+=(-i "$parent_xpath" -t attr -n "$attr_name" -v "$attr_value")
}

function xml_util::add_element() {
    local -n _cmd_array_ref="$1"
    local parent_xpath="$2"
    local element_name="$3"
    local element_value="$4"
    _cmd_array_ref+=(-s "$parent_xpath" -t elem -n "$element_name" -v "$element_value")
}

# NOTE: use '__cmd_array_ref' to avoid "circular reference" if the caller passes a variable '_cmd_array_ref'.
function xml_util::add_element_with_attr() {
    local -n __cmd_array_ref="$1"
    local parent_xpath="$2"
    local el_name="$3"
    local el_val="$4"
    local attr_name="$5"
    local attr_val="$6"

    # Add the element
    xml_util::add_element __cmd_array_ref "$parent_xpath" "$el_name" "$el_val"
    # Add the attribute to the newly created element (using last() to target it)
    xml_util::add_attribute __cmd_array_ref "${parent_xpath}/${el_name}[last()]" "$attr_name" "$attr_val"
}