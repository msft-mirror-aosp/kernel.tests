#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

# A handy tool to query build information by SQL.

# Define variables
F1_SERVER="/f1/query/prod"  # Default F1 server
OUTPUT_FILE="/tmp/build_query_output.csv"    # Output file for results
QUERY_TIMEOUT_SECONDS=3600 # Set query timeout to 1 hour
DATA_TABLE="android_testing_at_scale.atp.prod.build"

BOLD="$(tput bold)"
END="$(tput sgr0)"
GREEN="$(tput setaf 2)"
RED="$(tput setaf 198)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 34)"
MY_NAME="${0##*/}"

BRANCH=
BUILD_TARGET=
START_BUILD_ID=
END_BUILD_ID=

function print_info() {
    local log_prompt=$MY_NAME
    if [ -n "$2" ]; then
        log_prompt+=" line $2"
    fi
    echo "[$log_prompt]: ${GREEN}$1${END}"
}

function print_warn() {
    local log_prompt=$MY_NAME
    if [ -n "$2" ]; then
        log_prompt+=" line $2"
    fi
    echo "[$log_prompt]: ${YELLOW}$1${END}"
}

function print_error() {
    local log_prompt=$MY_NAME
    if [ -n "$2" ]; then
        log_prompt+=" line $2"
    fi
    echo -e "[$log_prompt]: ${RED}$1${END}"
    cd $OLD_PWD
    exit 1
}

function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script will get a list builds between two given builds."
    echo ""
    echo "Available options:"
    echo "  -br <branch>, --branch=<branch>"
    echo "                        The branch to search builds for"
    echo "  -bt <build_target>, --build-target=<build_target>"
    echo "                        The build target to search builds for"
    echo "  -sbid <start_build_id>, --start-build-id=<start_build_id>"
    echo "                        The start build_id."
    echo "  -ebid <end_build_id>, --end-build-id=<end_build_id>"
    echo "                        The end build build_id"
    echo "  -dt <data_table>, --data-table=<data_table>"
    echo "                        [Optional] The data table to query from"
    echo "                        If not specified, default to android_testing_at_scale.atp.prod.build"
    echo "  -o <output_file_path>, --output-file=<output_file_path>"
    echo "                        [Optional] The output file path"
    echo "                        If not specified, default to /tmp/build_query_output.csv"
    echo "  -h, --help"
    echo ""
    echo "Examples:"
    echo "$0 -br git_main -bt test_suites_arm64-trunk_food -sbid 13392337 -ebid 13392544"
    echo "$0 --branch=git_main --build-target=test_suites_arm64-trunk_food --start-build-id=13392337 -end-build-id=13392544"
    echo ""
    exit 0
}

function parse_arg() {
    while test $# -gt 0; do
        case "$1" in
            -h|--help)
                print_help
                ;;
            -br)
                shift
                if test $# -gt 0; then
                    BRANCH=$1
                else
                    print_error "branch is not specified"
                fi
                shift
                ;;
            --branch*)
                BRANCH=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -bt)
                shift
                if test $# -gt 0; then
                    BUILD_TARGET=$1
                else
                    print_error "build target is not specified"
                fi
                shift
                ;;
            --build-target*)
                BUILD_TARGET=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -sbid)
                shift
                if test $# -gt 0; then
                    START_BUILD_ID=$1
                else
                    print_error "start build ID is not specified"
                fi
                shift
                ;;
            --start-build-id*)
                START_BUILD_ID=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -ebid)
                shift
                if test $# -gt 0; then
                    END_BUILD_ID=$1
                else
                    print_error "end build ID is not specified"
                fi
                shift
                ;;
            --end-build-id*)
                END_BUILD_ID=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -o)
                shift
                if test $# -gt 0; then
                    OUTPUT_FILE=$1
                else
                    print_error "output file is not specified"
                fi
                shift
                ;;
            --output-file*)
                OUTPUT_FILE=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            -dt)
                shift
                if test $# -gt 0; then
                    DATA_TABLE=$1
                else
                    print_error "data table is not specified"
                fi
                shift
                ;;
            --data-table*)
                DATA_TABLE=$(echo $1 | sed -e "s/^[^=]*=//g")
                shift
                ;;
            *)
                print_error "Unsupported flag: $1" >&2
                ;;
        esac
    done
}

# Function to execute the SQL query
run_query() {
    local sql_query="$1"

    print_info "Query with SQL:" "$LINENO"
    echo "$sql_query"
    echo ""

    if [ -z "$sql_query" ]; then
        echo "Error: SQL query is empty."
        return 1
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
        print_info "Query execution completed successfully."
        print_info "Results saved to: ${OUTPUT_FILE}"
    else
        print_error "Error: Query execution failed."
    fi
}

# Main execution
main() {
    parse_arg "$@"
    if [ -z "$BRANCH" ]; then
        print_error "Branch is not provided with flag -br <branch> or --branch=<branch>." "$LINENO"
    fi
    if [ -z "$BUILD_TARGET" ]; then
        print_error "Build target is not provided with flag -bt <build_target> or --build-target=<build_target>." "$LINENO"
    fi
    if [ -z "$START_BUILD_ID" ]; then
        print_error "Start build ID is not provided with flag -sbid <start_build_id> or --start-build-id=<start_build_id>." "$LINENO"
    fi
    if [ -z "$END_BUILD_ID" ]; then
        print_error "End build ID is not provided with flag -ebid <end_build_id> or --end-build-id=<end_build_id>." "$LINENO"
    fi
    local sql_query="SELECT build_id, build_target, branch, arrival_timestamp, labels
    FROM $DATA_TABLE
    WHERE branch='$BRANCH' AND build_target='$BUILD_TARGET'
        AND REGEXP_CONTAINS(build_id, r'^[0-9]+$')
        AND CAST(build_id AS INT64) > CAST('$START_BUILD_ID' AS INT64)
        AND CAST(build_id AS INT64) <= CAST('$END_BUILD_ID' AS INT64)
    ORDER BY CAST(build_id AS INT64) ASC;"

  # Create output file if not exists
  if [ ! -f "${OUTPUT_FILE}" ]; then
    touch "${OUTPUT_FILE}"
  fi

  run_query "${sql_query}"
}

# Call the main function with the provided query as argument
main "$@"
