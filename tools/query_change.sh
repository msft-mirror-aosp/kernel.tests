#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# A handy tool to query change information by build ID by SQL.

F1_SERVER="/f1/query/prod"  # Default F1 server
DATA_TABLE="android_build.build_changes.last90days"
QUERY_TIMEOUT_SECONDS=3600
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"

LIB_PATH="${SCRIPT_DIR}/common_lib.sh"
# Import common_lib
if [[ ! -f "$LIB_PATH" ]]; then
    echo "FATAL ERROR: Cannot find required library '$LIB_PATH'" >&2
    exit 1
fi
if ! . "$LIB_PATH"; then
    echo "FATAL ERROR: Failed to source library '$LIB_PATH'" >&2
    exit 1
fi

BUILD_ID=
OUTPUT_FILE=

function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script will get change information into a CSV file for a provided build_id."
    echo ""
    echo "Available options:"
    echo "  -bid <build_id>, --build-id=<build_id>"
    echo "                        The build_id to search changes for"
    echo "  -o <output_file_path>, --output-file=<output_file_path>"
    echo "                        [Optional] The output CSV file path"
    echo "                        If not specified, default to /tmp/changes_<build_id>.csv"
    echo "  -h, --help"
    echo ""
    echo "Examples:"
    echo "$0 -bid 15129376"
    echo "$0 --build-id=15129376 --output-file=/tmp/my_changes.csv"
    echo ""
    exit 0
}

function parse_arg() {
    while test $# -gt 0; do
        case "$1" in
            -h|--help)
                print_help
                ;;
            -bid)
                shift
                if test $# -gt 0; then
                    BUILD_ID=$1
                else
                    log_error "build ID is not specified"
                    exit 1
                fi
                shift
                ;;
            --build-id*)
                BUILD_ID=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -o)
                shift
                if test $# -gt 0; then
                    OUTPUT_FILE=$1
                else
                    log_error "output file is not specified"
                    exit 1
                fi
                shift
                ;;
            --output-file*)
                OUTPUT_FILE=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            *)
                log_error "Unsupported flag: $1" >&2
                exit 1
                ;;
        esac
    done
}

# Function to execute the SQL query
run_query() {
    local sql_query="$1"

    log_info "Query with SQL:"
    echo "$sql_query"
    echo ""

    if [ -z "$sql_query" ]; then
        log_error "Error: SQL query is empty."
        exit 1
    fi

    # Construct the f1-sql command
    f1_cmd=(
        f1-sql
        --server="${F1_SERVER}"
        --csv_output=true
        --print_queries=false
        --query_timeout="${QUERY_TIMEOUT_SECONDS}"
        --input_file=/dev/stdin
        --output_file="${OUTPUT_FILE}"
    )

    # Execute the query using a "here string"
    printf "%s\n" "${sql_query}" | "${f1_cmd[@]}"

    if [ $? -eq 0 ]; then
        log_info "Query execution completed successfully."
        log_info "Results saved to: ${OUTPUT_FILE}"
    else
        log_error "Error: Query execution failed."
        exit 1
    fi
}

main() {
    parse_arg "$@"
    if [ -z "$BUILD_ID" ]; then
        log_error "Build ID is not provided with flag -bid <build_id> or --build-id=<build_id>."
        exit 1
    fi

    if [[ -z "$OUTPUT_FILE" || "$OUTPUT_FILE" == "/tmp/changes_<build_id>.csv" ]]; then
        OUTPUT_FILE="/tmp/changes_${BUILD_ID}.csv"
    fi

    local sql_query="
    SELECT
      build_id,
      change.latest_revision AS commit_id,
      change.submitted_time AS change_submit_time,
      change.project AS project,
      change.host AS host,
      change.branch AS branch,
      change.status AS status,
      change.creation_time AS change_creation_time,
      change.owner.name AS change_owner_name,
      change.owner.email AS change_owner_email,
      change.change_number AS change_number,
      change.change_id AS change_id,
      revision.commit.subject AS change_subject,
      revision.commit.commit_message AS change_commit_message,
      revision.commit.author.name AS change_author_name,
      revision.commit.author.email AS change_author_email,
      parent_commit.commit_id AS parent_commit_id
    FROM
      ${DATA_TABLE} AS a,
      UNNEST(a.change) AS change,
      UNNEST(change.revisions) AS revision,
      UNNEST(revision.commit.parent) AS parent_commit
    WHERE a.build_id='${BUILD_ID}';"

    # Create output file if not exists
    if [ ! -f "${OUTPUT_FILE}" ]; then
        touch "${OUTPUT_FILE}"
    fi

    run_query "${sql_query}"
}

main "$@"
