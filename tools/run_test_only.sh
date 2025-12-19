#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

#
# A simple script to run test in the local Android development environment.
#

PLATFORM_TF_PREBUILT=tools/tradefederation/prebuilts/filegroups/tradefed/tradefed.sh
GCOV=false
CREATE_TRACEFILE_SCRIPT="kernel/tests/tools/create-tracefile.py"
TRADEFED=
TRADEFED_GCOV_OPTIONS=" --coverage --coverage-toolchain GCOV_KERNEL --auto-collect GCOV_KERNEL_COVERAGE"
TEST_ARGS=()
TEST_DIR=
TEST_NAMES=()
USE_RBE=false
readonly REQUIRED_COMMANDS=("adb" "dirname")

function print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script will run tests on an Android device."
    echo ""
    echo "Available options:"
    echo "  -s <serial_number>, --serial=<serial_number>"
    echo "                        The device serial number to run tests with."
    echo "  -td <test_dir>, --test-dir=<test_dir> or -tb <test_build>, --test-build=<test_build>"
    echo "                        The test artifact file name or directory path."
    echo "                        Can be a local file or directory or a remote file"
    echo "                        as ab://<branch>/<build_target>/<build_id>/<file_name>."
    echo "                        If not specified, it will use the tests in the local"
    echo "                        repo."
    echo "  -tl <test_log_dir>, --test-log=<test_log_dir>"
    echo "                        The test log dir. Use default out/test_logs if not specified."
    echo "  -ta <test_arg>, --test-arg=<test_arg>"
    echo "                        Additional tradefed command arg. Can be repeated."
    echo "  -t <test_name>, --test=<test_name>  The test name. Can be repeated."
    echo "                        If test is not specified, no tests will be run."
    echo "  -tf <tradefed_binary_path>, --tradefed-bin=<tradefed_binary_path>"
    echo "                        The alternative tradefed binary to run test with."
    echo "  --gcov                Collect coverage data from the test result"
    echo "  --use-rbe             Enable Remote Build Execution to speed up testing process."
    echo "                        Requires RBE service access; See go/build-fast for details."
    echo "  -h, --help            Display this help message and exit"
    echo ""
    echo "Examples:"
    echo "$0 -s 127.0.0.1:33847 -t selftests"
    echo "$0 -s 1C141FDEE003FH -t selftests:kselftest_binderfs_binderfs_test"
    echo "$0 -s 127.0.0.1:33847 -t CtsAccessibilityTestCases -t CtsAccountManagerTestCases"
    echo "$0 -s 127.0.0.1:33847 -t CtsAccessibilityTestCases -t CtsAccountManagerTestCases \
-td ab://aosp-main/test_suites_x86_64-trunk_staging/latest/android-cts.zip"
    echo "$0 -s 1C141FDEE003FH -t CtsAccessibilityTestCases -t CtsAccountManagerTestCases \
-td ab://git_main/test_suites_arm64-trunk_staging/latest/android-cts.zip"
    echo "$0 -s 1C141FDEE003FH -t CtsAccessibilityTestCases -td <your_path_to_platform_repo>"
    echo "$0 -s 1C141FDEE003FH -t selftests \
-td ab://aosp_kernel-common-android-mainline/kernel_aarch64/latest/tests.zip"
    echo "$0 -s 1C141FDEE003FH -t selftests \
-td ab://aosp_kernel-common-android-mainline/kernel_aarch64/latest/tests.zip \
-tf ab://tradefed/tradefed/latest/google-tradefed.zip"
    echo ""
    exit 0
}

function sync_platform_repo() {
    local product_to_build="$1"
    local build_type="$2"
    local repo_root_path="$3"

    local is_current_product_x86=false
    if [[ "${TARGET_PRODUCT}" == *"x86"* ]]; then
        is_current_product_x86=true
    fi

    local is_new_product_x86=false
    if [[ "${product_to_build}" == *"x86"* ]]; then
        is_new_product_x86=true
    fi

    if [[ -z "${TARGET_PRODUCT}" || "${is_current_product_x86}" != "${is_new_product_x86}" ]]; then
        log_warn "Build target product ('${TARGET_PRODUCT}') does not match device product ('${product_to_build}'). Resetting build environment."
        set_platform_repo "${product_to_build}" "${build_type}" "${repo_root_path}"
    fi

    if [[ -z "$ANDROID_HOST_OUT" || -z "$TARGET_PRODUCT" ]]; then
        log_error "'lunch' tool failed to configure build variants. Please check."
        exit 1
    fi
}

function run_atest_in_platform_repo() {
    local product="$1"
    local build_type="$2"
    local repo_root_path="$3"

    sync_platform_repo "${product}" "${build_type}" "${repo_root_path}"

    local atest_cli=""
    if [[ "$USE_RBE" == false ]]; then
        atest_cli+="USE_RBE=false RBE_ENABLED=false "
    fi
    atest_cli+="atest ${TEST_NAMES[*]} -s $SERIAL_NUMBER --"
    if $GCOV; then
        atest_cli+="$TRADEFED_GCOV_OPTIONS"
    fi
    log_info "Running the test with ATest: $atest_cli ${TEST_ARGS[*]}"
    eval "$atest_cli" "${TEST_ARGS[*]}"
    exit_code=$?

    if $GCOV; then
        atest_log_dir="/tmp/atest_result_$USER/LATEST"
        create_tracefile_cli="$CREATE_TRACEFILE_SCRIPT -t $atest_log_dir/log -o $atest_log_dir/cov.info"
        log_info "Skip creating tracefile. If you have full kernel source, run the following command:"
        log_info "$create_tracefile_cli"
    fi
    cd $OLD_PWD
    exit $exit_code
}

function unset_android_environment() {
    for var in $(env); do
      # Extract the variable name
      var_name="${var%%=*}"
      # Check if the variable name starts with "ANDROID"
      if [[ "$var_name" == "ANDROID"* ]]; then
        # Unset the variable
        unset "$var_name"
      fi
    done
}

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$( cd "$( dirname "${SCRIPT_PATH}" )" &> /dev/null && pwd -P)"
LIB_PATH="${SCRIPT_DIR}/common_lib.sh"
if [[ -f "$LIB_PATH" ]]; then
    if ! . "$LIB_PATH"; then
        echo "Fatal Error：Cannot load library '$LIB_PATH'" >&2
        exit 1
    fi
else
    echo "Fatal Error：Cannot find library '$LIB_PATH'" >&2
    exit 1
fi

OLD_PWD=$PWD
MY_NAME=$0

while (( $# > 0 )); do
    case "$1" in
        -h|--help)
            print_help
            ;;
        -s)
            shift
            if (( $# > 0 )); then
                SERIAL_NUMBER="$1"
            else
                print_error "device serial is not specified"
            fi
            shift
            ;;
        --serial*)
            SERIAL_NUMBER="$(echo "$1" | sed -e "s/^[^=]*=//g")"
            shift
            ;;
        -tl)
            shift
            if (( $# > 0 )); then
                LOG_DIR="$1"
            else
                print_error "test log directory is not specified"
            fi
            shift
            ;;
        --test-log*)
            LOG_DIR=$(echo "$1" | sed -e "s/^[^=]*=//g")
            shift
            ;;
        -td | -tb )
            shift
            if (( $# > 0 )); then
                TEST_DIR="$1"
            else
                print_error "test directory is not specified"
            fi
            shift
            ;;
        --test-dir* | --test-build*)
            TEST_DIR=$(echo "$1" | sed -e "s/^[^=]*=//g")
            shift
            ;;
        -ta)
            shift
            if (( $# > 0 )); then
                TEST_ARGS+=("$1")
            else
                print_error "test arg is not specified"
            fi
            shift
            ;;
        --test-arg*)
            TEST_ARGS+=($(echo $1 | sed -e "s/^[^=]*=//g"))
            shift
            ;;
        -t)
            shift
            if (( $# > 0 )); then
                TEST_NAMES+=("$1")
            else
                print_error "test name is not specified"
            fi
            shift
            ;;
        --test*)
            TEST_NAMES+=("$(echo "$1" | sed -e "s/^[^=]*=//g")")
            shift
            ;;
        -tf)
            shift
            if (( $# > 0 )); then
                TRADEFED="$1"
            else
                print_error "tradefed binary is not specified"
            fi
            shift
            ;;
        --tradefed-bin*)
            TRADEFED="$(echo "$1" | sed -e "s/^[^=]*=//g")"
            shift
            ;;
        --gcov)
            GCOV=true
            shift
            ;;
        --use-rbe)
            USE_RBE=true
            shift
            ;;
        *)
            print_error "Unsupported flag: $1" >&2
            ;;
    esac
done

# Ensure SERIAL_NUMBER is provided
if [[ -z "$SERIAL_NUMBER" ]]; then
    log_error "Device serial is not provided with flag -s <serial_number>."
    exit 1
fi

# Ensure TEST_NAMES is provided
if [[ -z "$TEST_NAMES" ]]; then
    log_error "No test is specified with flag -t <test_name>."
    exit 1
fi

FULL_COMMAND_PATH=$(dirname "$PWD/$0")
REPO_LIST_OUT=$(repo list 2>&1)
if [[ "$REPO_LIST_OUT" == "error"* ]]; then
    log_warn "Current path $PWD is not in an Android repo. Change path to repo root."
    go_to_repo_root "$FULL_COMMAND_PATH"
    log_info "Changed path to $PWD"
else
    go_to_repo_root "$PWD"
fi

REPO_ROOT_PATH="$PWD"
readonly FETCH_SCRIPT="$REPO_ROOT_PATH/$FETCH_SCRIPT_PATH_IN_REPO"
DEFAULT_LOG_DIR="$PWD/out/test_logs/$(date +%Y%m%d_%H%M%S)"

log_info "Checking required commands..."
if ! check_commands_available "${REQUIRED_COMMANDS[@]}"; then
    log_error "One or more required commands are missing. Please install them and retry."
    exit 1
fi

# Set default LOG_DIR if not provided
if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR="$DEFAULT_LOG_DIR"
fi

BOARD=$(adb -s "$SERIAL_NUMBER" shell getprop ro.product.board)
ABI=$(adb -s "$SERIAL_NUMBER" shell getprop ro.product.cpu.abi)
PRODUCT=$(adb -s "$SERIAL_NUMBER" shell getprop ro.product.product.name)
BUILD_TYPE=$(adb -s "$SERIAL_NUMBER" shell getprop ro.build.type)

if [[ -z "$TEST_DIR" ]]; then
    log_warn "Flag -td <test_dir> is not provided. Will use the default test directory"
    if [[ "$REPO_LIST_OUT" == *"build/make"* ]]; then
        # In the platform repo
        run_atest_in_platform_repo "${PRODUCT}" "${BUILD_TYPE}" "${REPO_ROOT_PATH}"
    elif [[ "$BOARD" == "cutf"* && "$REPO_LIST_OUT" == *"common-modules/virtual-device"* ]]; then
        # In the android kernel repo
        if [[ "$ABI" == "arm64"* ]]; then
            TEST_DIR="$REPO_ROOT_PATH/out/virtual_device_aarch64/dist/tests.zip"
            log_warn "Will try find test $TEST_NAMES in $TEST_DIR. Please make sure you have re-build \
the tests if there is change by: tools/bazel run //common-modules/virtual-device:virtual_device_aarch64_dist."
        elif [[ "$ABI" == "x86_64"* ]]; then
            TEST_DIR="$REPO_ROOT_PATH/out/virtual_device_x86_64/dist/tests.zip"
            log_warn "Will try find test $TEST_NAMES in $TEST_DIR. Please make sure you have re-build \
the tests if there is change by: tools/bazel run //common-modules/virtual-device:virtual_device_x86_64_dist."
        else
            log_error "No test builds for $ABI Cuttlefish in $REPO_ROOT_PATH"
            exit 1
        fi
    elif [[ "$BOARD" == "raven"* || "$BOARD" == "oriole"* && "$REPO_LIST_OUT" == *"private/google-modules/display"* ]]; then
        TEST_DIR="$REPO_ROOT_PATH/out/slider/dist/tests.zip"
        log_warn "Will try find test $TEST_NAMES in $TEST_DIR. Please make sure you have re-build \
the tests if there is change."
    elif [[ "$ABI" == "arm64"* && "$REPO_LIST_OUT" == *"kernel/common"* ]]; then
        TEST_DIR="$REPO_ROOT_PATH/out/kernel_aarch64/dist/tests.zip"
        log_warn "Will try find test $TEST_NAMES in $TEST_DIR. Please make sure you have re-build \
the tests if there is change by: tools/bazel run //common:kernel_aarch64_dist."
    else
        log_error "No test builds for $ABI $BOARD in $REPO_ROOT_PATH"
        exit 1
    fi
fi

TEST_FILTERS=
for i in "${TEST_NAMES[@]}"; do
    _test_name=$(echo $i | sed "s/:/ /g")
    TEST_FILTERS+=" --include-filter '$_test_name'"
done

if [[ "$TEST_DIR" == ab://* ]]; then
    updated_ab_string=""
    if ! convert_ab_string "$TEST_DIR" updated_ab_string; then
        log_error "Invalid Android Build string $TEST_DIR."
        exit 1
    fi
    eval "$FETCH_SCRIPT $updated_ab_string"
    exit_code=$?
    if (( exit_code == 0 )); then
        log_info "$updated_ab_string is downloaded successfully"
    else
        log_error "Failed to download $updated_ab_string"
        exit 1
    fi
    file_name="${updated_ab_string/ab:\/\//}"
    TEST_DIR="$DOWNLOAD_PATH/$file_name"
    cd "$REPO_ROOT_PATH"
elif [[ -n "$TEST_DIR" ]]; then
    if [[ -d $TEST_DIR ]]; then
        test_file_path=$TEST_DIR
    elif [[ -f "$TEST_DIR" ]]; then
        test_file_path=$(dirname "$TEST_DIR")
    else
        log_error "$TEST_DIR is neither a directory nor a file."
        exit 1
    fi
    cd "$test_file_path" || { log_error "Failed to go to $test_file_path"; exit 1; }
    TEST_REPO_LIST_OUT=$(repo list 2>&1)
    if [[ "$TEST_REPO_LIST_OUT" == "error"* ]]; then
        log_info "Test path $test_file_path is not in an Android repo. Will use $TEST_DIR directly."
    elif [[ "$TEST_REPO_LIST_OUT" == *"build/make"* ]]; then
        # Test_dir is from the platform repo
        log_info "Test_dir $TEST_DIR is from Android platform repo. Run test with atest..."
        go_to_repo_root "$PWD"
        run_atest_in_platform_repo "${PRODUCT}" "${BUILD_TYPE}" "${PWD}"
    fi
fi

if [[ "$TRADEFED" == ab://* ]]; then
    updated_ab_string=""
    if ! convert_ab_string "$TRADEFED" updated_ab_string; then
        log_error "Invalid Android Build string $TRADEFED."
        exit 1
    fi
    eval "$FETCH_SCRIPT $updated_ab_string"
    exit_code=$?
    if (( exit_code == 0 )); then
        log_info "$updated_ab_string is downloaded successfully"
    else
        log_error "Failed to download $updated_ab_string"
        exit 1
    fi

    file_name="$DOWNLOAD_PATH/${updated_ab_string/ab:\/\//}"
    # Check if the download was successful
    if [[ ! -f "$file_name" ]]; then
        log_error "Failed to download ${file_name}"
        exit 1
    fi
    tf_dir="${file_name/.zip/}"
    if [[ -d "$tf_dir" ]]; then
        log_info "$file_name is already unzipped in $tf_dir. Skip Unzip."
    else
        unzip -oq "$file_name" -d "$tf_dir" || { log_error "Failed to unzip $file_name to $tf_dir"; exit 1; }
    fi
    TRADEFED=$(find "$tf_dir" -type f -name "tradefed.sh" -executable)
    if [[ -z "$TRADEFED" ]]; then
        log_error "Could not find tradefed.sh in $tf_dir"
        exit 1
    fi
    create_soft_link "$tf_dir" "$TRADEFED_DIR"
fi

cd "$REPO_ROOT_PATH"
if [[ "$TEST_DIR" == *.zip ]]; then
    filename=${TEST_DIR##*/}
    new_test_dir="${TEST_DIR%.*}"
    if [[ -d "$new_test_dir" ]]; then
        log_info "$TEST_DIR is already unzipped to $new_test_dir. No need to unzip again"
    else
        unzip -oq "$TEST_DIR" -d "$new_test_dir" || { log_error "Failed to unzip $TEST_DIR to $new_test_dir"; exit 1; }
    fi
    case $filename in
        "android-vts.zip" | "android-cts.zip")
        new_test_dir+="/$(echo $filename | sed "s/.zip//g")"
        ;;
        *)
        ;;
    esac
    TEST_DIR="$new_test_dir" # Update TEST_DIR to the unzipped directory
fi

log_info "Will run tests with test artifacts in $TEST_DIR"

tf_cli=$(find "$TEST_DIR" -type f -name "[cv]ts-tradefed" -executable)
testcases_path=$(find "$TEST_DIR" -type d -name "testcases")
if [[ -n "$tf_cli" && -n "$testcases_path" ]]; then
    xts=$(basename "$tf_cli" | cut -d'-' -f1)
    log_info "Will run tests with ${xts}-tradefed from $TEST_DIR"
    log_info "Many ${xts^^} tests need WIFI connection, please make sure WIFI is connected before you run the test."
    tf_cli+=" run commandAndExit ${xts} --skip-device-info --log-level-display info"
    TEST_DIR=$(dirname "$testcases_path")
    unset_android_environment
else
    if [[ -n "$TRADEFED" ]]; then
        if [[ "$REPO_LIST_OUT" == *"kernel/common"* ]]; then
            # In Android kernel tree
            tf_cli="JAVA_HOME=$KERNEL_JDK_PATH PATH=$KERNEL_JDK_PATH/bin:$PATH $TRADEFED run commandAndExit"
        elif [[ "$REPO_LIST_OUT" == *"build/make"* ]]; then
            # In Android platform tree
            tf_cli="JAVA_HOME=$PLATFORM_JDK_PATH PATH=$PLATFORM_JDK_PATH/bin:$PATH $TRADEFED run commandAndExit"
        else
            tf_cli="$TRADEFED run commandAndExit"
        fi
    elif [[ -f "${ANDROID_HOST_OUT}/bin/tradefed.sh" ]]; then
        TRADEFED="${ANDROID_HOST_OUT}/bin/tradefed.sh"
        tf_cli="$TRADEFED run commandAndExit"
    elif [[ -f "$PLATFORM_TF_PREBUILT" ]]; then
        TRADEFED="$PLATFORM_TF_PREBUILT"
        tf_cli="JAVA_HOME=$PLATFORM_JDK_PATH PATH=$PLATFORM_JDK_PATH/bin:$PATH $TRADEFED run commandAndExit"
    elif [[ -f "${TRADEFED_DIR}/tradefed.sh" ]]; then
        TRADEFED="${TRADEFED_DIR}/tradefed.sh"
        tf_cli="$TRADEFED run commandAndExit"
    # No Tradefed found
    else
        log_error "Can not find Tradefed binary. Please use flag -tf to specify the binary path. \
For example -tf ab://tradefed/tradefed/latest/tradefed.zip"
        exit 1
    fi
    log_info "Use Tradefed from $TRADEFED"
    tf_cli+=" template/local_min --template:map test=suite/test_mapping_suite --tests-dir=$TEST_DIR"
fi

tf_cli+=" $TEST_FILTERS --log-level-display info --log-file-path=$LOG_DIR -s $SERIAL_NUMBER"
# Add GCOV options if enabled
if $GCOV; then
    tf_cli+=" --enable-root"
    tf_cli+=$TRADEFED_GCOV_OPTIONS
fi

# Evaluate the TradeFed command with extra arguments
log_info "Run test with: $tf_cli ${TEST_ARGS[*]}"
eval "$tf_cli" "${TEST_ARGS[*]}"
exit_code=$?

if $GCOV; then
    create_tracefile_cli="$CREATE_TRACEFILE_SCRIPT -t $LOG_DIR -o $LOG_DIR/cov.info"
    if [[ "$REPO_LIST_OUT" == *"kernel/common"* ]]; then
        log_info "Create tracefile with $create_tracefile_cli"
        $create_tracefile_cli && \
        log_info "Created tracefile at $LOG_DIR/cov.info"
    else
        log_info "Skip creating tracefile. If you have full kernel source, run the following command:"
        log_info "$create_tracefile_cli"
    fi
fi

cd $OLD_PWD
if (( exit_code > 0 )); then
    exit $exit_code
fi

INVOCATION_SUMMARY="$TEST_DIR/results/latest/invocation_summary.txt"
if [[ ! -f "$INVOCATION_SUMMARY" ]]; then
    log_error "File ${INVOCATION_SUMMARY} not found."
    exit 1
fi

total_tests_number=$(grep "Total Tests[[:space:]]*:" "$INVOCATION_SUMMARY" | awk -F ":" '{print $NF}' | tr -d ' ')
if [[ -z "$total_tests_number" ]]; then
    log_error "Could not find 'Total Tests' in the invocation summary file."
    exit 1
fi

if (( total_tests_number == 0 )); then
    log_error "Total Tests is 0. A specific test module might have crashed."
    exit 1
fi

failure_number=$(grep "FAILED[[:space:]]*:" "$INVOCATION_SUMMARY" | awk -F ":" '{print $NF}' | tr -d ' ')
if [[ -n "$failure_number" ]]; then
    if (( failure_number == 0 )); then
        log_info "There is no test failure."
    elif (( failure_number == 1 )); then
        log_error "There is a test failure."
        exit 1
    else
        log_error "There are $failure_number test failures."
        exit 1
    fi
else
    log_error "$INVOCATION_SUMMARY doesn't have 'FAILED :' line"
    exit 1
fi