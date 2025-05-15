#!/usr/bin/env bash

# --- Test Configuration ---
readonly SCRIPT_DIR=$(dirname $(realpath "${BASH_SOURCE[0]}"))
readonly COMMON_LIB_PATH="${SCRIPT_DIR}/common_lib.sh"
readonly SHUNIT2_PATH="${SCRIPT_DIR}/../../../external/shflags/lib/shunit2"

# --- Global Test Variables ---
TEST_TEMP_DIR=""
MOCK_REPO_DIR=""
MOCK_PLATFORM_DIR=""
ORIGINAL_PATH="" # To store original PATH for restoration

# --- Test Suite Setup ---
oneTimeSetUp() {
    # Save original PATH
    ORIGINAL_PATH="$PATH"

    # Ensure common_lib.sh is found and source it
    if [[ ! -f "${COMMON_LIB_PATH}" ]]; then
        echo "FATAL ERROR: Cannot find required library '$COMMON_LIB_PATH'" >&2
        exit 1
    fi

    if ! . "${COMMON_LIB_PATH}" >/dev/null; then
        echo "FATAL ERROR: Failed to source library '$COMMON_LIB_PATH'. Check common_lib.sh dependencies." >&2
        exit 1
    fi

    # Create a temporary directory for test artifacts
    TEST_TEMP_DIR=$(mktemp -d -t common_lib_test_XXXXXX)

    # Setup common mock directories and files
    MOCK_REPO_DIR="${TEST_TEMP_DIR}/mock_repo_root"
    mkdir -p "${MOCK_REPO_DIR}/.repo"

    MOCK_PLATFORM_DIR="${TEST_TEMP_DIR}/mock_platform_repo"
    mkdir -p "${MOCK_PLATFORM_DIR}/.repo/manifests"
    mkdir -p "${MOCK_PLATFORM_DIR}/build/make"
    mkdir -p "${MOCK_PLATFORM_DIR}/build/soong" # For platform check
    mkdir -p "${MOCK_PLATFORM_DIR}/build/release/release_configs"
    # Create a mock envsetup.sh
    cat <<-'EOF' > "${MOCK_PLATFORM_DIR}/build/envsetup.sh"
#!/bin/sh
lunch() {
    echo "Mock lunch executing for target: $1"
    if echo "$1" | grep -q "error"; then
        echo "error: Mock lunch encountered an error for $1" >&2
        return 1
    elif echo "$1" | grep -q "no_lunch_cmd"; then
        # This case should not happen if sourced correctly, but for testing check_command
        echo "Error: lunch command was expected to be defined." >&2
        return 127 # command not found
    else
        # Simulate setting some environment variables
        export TARGET_PRODUCT=$(echo "$1" | cut -d- -f1)
        export TARGET_BUILD_VARIANT=$(echo "$1" | cut -d- -f3)
        echo "Mock TARGET_PRODUCT=${TARGET_PRODUCT}"
        echo "Mock TARGET_BUILD_VARIANT=${TARGET_BUILD_VARIANT}"
        return 0
    fi
}
EOF
    chmod +x "${MOCK_PLATFORM_DIR}/build/envsetup.sh"
}

oneTimeTearDown() {
    # Clean up temporary directory
    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
    # Restore original PATH
    PATH="$ORIGINAL_PATH"
    # Unset any global variables
    unset TEST_TEMP_DIR MOCK_REPO_DIR MOCK_PLATFORM_DIR ORIGINAL_PATH
}

setUp() {
    cd "${TEST_TEMP_DIR}" || exit 1
    # Restore PATH to original before each test, specific mocks will modify it per test
    PATH="$ORIGINAL_PATH"
    # Clear any environment variables that might be set by functions under test
    unset MY_TEST_VAR MY_EMPTY_VAR TARGET_PRODUCT TARGET_BUILD_VARIANT
}

tearDown() {
    # Runs after each test function
    # Clean up any files created by a specific test if not in TEST_TEMP_DIR root
    # Ensure PATH is restored if a test modified it and didn't clean up (though individual tests should)
    PATH="$ORIGINAL_PATH"
}

# --- Empty suite() function ---
# This will prevent the "command not found" error, and shunit2 will then
# proceed to its auto-detection logic for "test_..." functions.
suite() {
    :
}

# --- Helper function to mock commands ---
# Usage: _mock_command "cmd_name" "exit_code" "stdout_message" "stderr_message"
_mock_command() {
    local cmd_name="$1"
    local exit_code="${2:-0}"
    local stdout_msg="${3:-}"
    local stderr_msg="${4:-}"

    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/${cmd_name}" <<-EOF
#!/bin/sh
# Mock for ${cmd_name}
if [ -n "${stderr_msg}" ]; then echo "${stderr_msg}" >&2; fi
if [ -n "${stdout_msg}" ]; then echo "${stdout_msg}"; fi
exit ${exit_code}
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/${cmd_name}"
    PATH="${TEST_TEMP_DIR}/bin:${PATH}"
}

# --- Test Cases ---

# Test _timestamp
test__timestamp_format() {
    local ts
    ts=$(_timestamp)
    local status=$?
    assertEquals "_timestamp should succeed" 0 "${status}"
    assertTrue "_timestamp should return a non-empty string" "[ -n \"${ts}\" ]"
    # Basic check for ISO-like format (YYYY-MM-DD)
    assertContains "_timestamp output should contain YYYY-MM-DD" "${ts}" "$(date +%Y-%m-%d)"
}

test__timestamp_date_fails() {
    _mock_command "date" 1 "" "mock date failure" # Mock date to fail

    local stdout_val stderr_val
    # Capture stdout and _timestamp's direct stderr separately
    # Subshell to capture stdout correctly
    stdout_val=$( ( _timestamp ) 2> "${TEST_TEMP_DIR}/stderr.txt" )
    local status=$?
    stderr_val=$(cat "${TEST_TEMP_DIR}/stderr.txt")
    rm "${TEST_TEMP_DIR}/stderr.txt"

    assertEquals "_timestamp should return 1 if all date attempts fail" 1 "${status}"
    assertTrue "_timestamp stdout should be empty if all date attempts fail" "[ -z \"${stdout_val}\" ]"
    assertContains "Stderr from _timestamp should contain TIMESTAMP_ERR" "${stderr_val}" "TIMESTAMP_ERR"
}

# Test log_info, log_warn, log_error
test_log_info_runs() {
    local stdout_val stderr_val
    stdout_val=$(log_info "Test info message" 2> "${TEST_TEMP_DIR}/stderr.txt")
    stderr_val=$(cat "${TEST_TEMP_DIR}/stderr.txt")
    rm "${TEST_TEMP_DIR}/stderr.txt"

    assertTrue "log_info should not fail (return 0)" $? # log_info itself has no return, relies on _print_log
    assertContains "log_info stdout should contain INFO and message" "${stdout_val}" "INFO"
    assertContains "log_info stdout should contain the message" "${stdout_val}" "Test info message"
    assertTrue "log_info stderr should be empty" "[ -z \"${stderr_val}\" ]"
}

test_log_warn_runs_and_returns_zero() {
    local stderr_val stdout_val
    stderr_val=$(log_warn "Test warn message" 2>&1 1>"${TEST_TEMP_DIR}/stdout.txt") # Capture combined, then filter
    local status=$?
    stdout_val=$(cat "${TEST_TEMP_DIR}/stdout.txt")
    rm "${TEST_TEMP_DIR}/stdout.txt"

    assertEquals "log_warn should return 0" 0 "${status}"
    assertContains "log_warn stderr should contain WARN and message" "${stderr_val}" "WARN"
    assertContains "log_warn stderr should contain the message" "${stderr_val}" "Test warn message"
    assertTrue "log_warn stdout should be empty" "[ -z \"${stdout_val}\" ]"
}

test_log_warn_with_exit_code_context() {
    local stderr_val
    stderr_val=$(log_warn "Test warn message with context" 123 2>&1 >/dev/null)
    local status=$?
    assertEquals "log_warn with context should return 0" 0 "${status}"
}

test_log_error_runs_and_returns_code() {
    local stderr_val
    stderr_val=$(log_error "Test error message" 5 2>&1 >/dev/null)
    local status=$?
    assertEquals "log_error should return the specified exit code" 5 "${status}"
    assertContains "log_error stderr should contain ERROR and message" "${stderr_val}" "ERROR"
    assertContains "log_error stderr should contain the message" "${stderr_val}" "Test error message"
    assertContains "log_error output should contain exit code" "${stderr_val}" "Exit Code 5"
}

test_log_error_default_exit_code() {
    log_error "Test error message default" >/dev/null 2>&1
    local status=$?
    assertEquals "log_error should return 1 by default" 1 "${status}"
}

test_log_error_non_numeric_exit_code() {
    log_error "Test error with non-numeric code" "invalid" >/dev/null 2>&1
    local status=$?
    assertEquals "log_error should return 1 for non-numeric code" 1 "${status}"
}

# Test check_command
test_check_command_exists() {
    assertTrue "check_command for 'echo' should return true (0)" "check_command echo"
}

test_check_command_not_exists() {
    assertFalse "check_command for 'non_existent_command_xyz' should return false (1)" "check_command non_existent_command_xyz"
}

test_check_command_empty_arg() {
    # Behavior of `command -v ""` can vary. Bash returns 0, others might return 1.
    # common_lib.sh uses #!/usr/bin/env bash, so test bash behavior.
    local stderr_val
    stderr_val=$(check_command "" 2>&1)
    local status=$?
    # In Bash, `command -v ""` is true, set up guard clause.
    assertEquals "check_command with empty string should return 1 in bash" 1 "${status}"
    assertContains "Error message should contain 'Usage: check_command <cmd>'" "${stderr_val}" "Usage: check_command <cmd>"
}

# Test check_commands_available
test_check_commands_available_all_exist() {
    check_commands_available echo true cat
    local status=$?
    assertEquals "check_commands_available for 'echo', 'true', 'cat' should succeed (0)" 0 "${status}"
}

test_check_commands_available_one_missing() {
    local stderr_val
    stderr_val=$(check_commands_available echo non_existent_cmd_789 true 2>&1 >/dev/null)
    local status=$?
    assertEquals "check_commands_available with one missing should return 1" 1 "${status}"
    assertContains "Error message should contain 'non_existent_cmd_789'" "${stderr_val}" "'non_existent_cmd_789'"
}

test_check_commands_available_no_args() {
    local warn_output
    warn_output=$(check_commands_available 2>&1 >/dev/null)
    local status=$?
    assertEquals "check_commands_available with no args should return 0" 0 "${status}"
    assertContains "Warning message should indicate no commands provided" "${warn_output}" "No commands provided"
}

# Test find_repo_root
test_find_repo_root_is_current_dir() {
    mkdir -p "${TEST_TEMP_DIR}/current_is_root/.repo"
    cd "${TEST_TEMP_DIR}/current_is_root" || exit 1
    local found_root
    found_root=$(find_repo_root "$PWD") # Use PWD directly for clarity
    local status=$?
    assertEquals "find_repo_root status should be 0" 0 "${status}"
    assertEquals "find_repo_root should find current dir" "$PWD" "${found_root}"
}

test_find_repo_root_is_parent_dir() {
    mkdir -p "${MOCK_REPO_DIR}/subdir1/subdir2" # MOCK_REPO_DIR has .repo
    cd "${MOCK_REPO_DIR}/subdir1/subdir2" || exit 1
    local found_root
    found_root=$(find_repo_root ".")
    local status=$?
    assertEquals "find_repo_root status should be 0" 0 "${status}"
    assertEquals "find_repo_root should find MOCK_REPO_DIR" "${MOCK_REPO_DIR}" "${found_root}"
}

test_find_repo_root_not_found() {
    mkdir -p "${TEST_TEMP_DIR}/no_repo_here"
    cd "${TEST_TEMP_DIR}/no_repo_here" || exit 1
    local found_root stderr_log
    found_root=$(find_repo_root . 2> "${TEST_TEMP_DIR}/stderr.txt")
    local status=$?
    stderr_log=$(cat "${TEST_TEMP_DIR}/stderr.txt")
    rm "${TEST_TEMP_DIR}/stderr.txt"
    assertEquals "find_repo_root status should be 1 when not found" 1 "${status}"
    assertTrue "find_repo_root stdout should be empty when not found" "[ -z \"${found_root}\" ]"
    assertContains "Error message should indicate no .repo directory" "${stderr_log}" "No .repo directory found"
}

# Test go_to_repo_root
test_go_to_repo_root_success() {
    local start_path="${MOCK_REPO_DIR}/some_subdir_for_go_to" # MOCK_REPO_DIR has .repo
    mkdir -p "${start_path}"
    cd "${start_path}" || exit 1

    local original_pwd="$PWD"
    local info_log
    go_to_repo_root "."    1>"${TEST_TEMP_DIR}/stdout.txt"
    local status=$?
    info_log=$(cat "${TEST_TEMP_DIR}/stdout.txt")
    rm "${TEST_TEMP_DIR}/stdout.txt"
    assertEquals "go_to_repo_root should succeed" 0 "${status}"
    assertEquals "Should change directory to MOCK_REPO_DIR" "${MOCK_REPO_DIR}" "$PWD"
    assertContains "Log should indicate success" "${info_log}" "Successfully changed directory to repo root"
    cd "${original_pwd}" # Go back
}

# Test is_in_repo_workspace
test_is_in_repo_workspace_true() {
    _mock_command "repo" 0 "mock repo list output" "" # Mock 'repo list' to succeed
    is_in_repo_workspace "${TEST_TEMP_DIR}"
    local status=$?
    assertEquals "is_in_repo_workspace should return 0 when 'repo list' succeeds" 0 "${status}"
}

test_is_in_repo_workspace_false() {
    _mock_command "repo" 1 "" "mock repo list error" # Mock 'repo list' to fail
    local warn_log
    warn_log=$(is_in_repo_workspace "${TEST_TEMP_DIR}" 2>&1 >/dev/null)
    local status=$?
    # Modified
    assertEquals "is_in_repo_workspace should return 1 when 'repo list' fails" 1 "${status}"
    assertContains "Warning log should contain 'repo list command failed'" "${warn_log}" "'repo list' command failed"
}

# Test is_repo_root_dir
test_is_repo_root_dir_true() {
    _mock_command "repo" 0 # Mock 'repo list' to succeed
    local info_log
    info_log=$(is_repo_root_dir "${MOCK_REPO_DIR}" 2>/dev/null) # MOCK_REPO_DIR has .repo
    local status=$?
    assertEquals "is_repo_root_dir should return 0 for valid repo root" 0 "${status}"
    assertContains "Info log should confirm valid repo root" "${info_log}" "Confirmed valid repo root directory"
}

# Test is_platform_repo
test_is_platform_repo_true() {
    # MOCK_PLATFORM_DIR has .repo and build/make
    # Mock 'repo list' and 'repo list -p'
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/repo" <<-EOF
#!/bin/sh
if [ "\$1" = "list" ] && [ "\$2" = "-p" ]; then echo "kernel/common build/make some/other"; exit 0; fi
if [ "\$1" = "list" ]; then exit 0; fi
exit 1
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/repo"
    PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    local info_log
    info_log=$(is_platform_repo "${MOCK_PLATFORM_DIR}" 2>/dev/null)
    local status=$?
    assertEquals "is_platform_repo should return 0 for valid platform repo" 0 "${status}"
    assertContains "Info log should confirm platform repo" "${info_log}" "Confirmed Android Platform repository"
}

test_is_platform_repo_not_platform_heuristic_fails() {
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/repo" <<-EOF
#!/bin/sh
if [ "\$1" = "list" ] && [ "\$2" = "-p" ]; then echo "some/other/project"; exit 0; fi
if [ "\$1" = "list" ]; then exit 0; fi
exit 1
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/repo"
    PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    local warn_log
    warn_log=$(is_platform_repo "${MOCK_REPO_DIR}" 2>&1 >/dev/null) # MOCK_REPO_DIR has .repo but -p output won't match
    local status=$?
    assertEquals "is_platform_repo should return 1 if heuristic fails" 1 "${status}"
    assertContains "Warn log should indicate heuristic check failed" "${warn_log}" "may not be an Android Platform repository"
}

# Test set_platform_repo
test_set_platform_repo_success() {
    # MOCK_PLATFORM_DIR has mock envsetup.sh & .repo, build/make
    # Mock 'repo list' and 'repo list -p' for is_platform_repo to pass
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/repo" <<-EOF
#!/bin/sh
if [ "\$1" = "list" ] && [ "\$2" = "-p" ]; then echo "kernel/common build/make"; exit 0; fi
if [ "\$1" = "list" ]; then exit 0; fi
exit 1
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/repo"
    PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    local output_log
    output_log=$(set_platform_repo "myproduct" "userdebug" "${MOCK_PLATFORM_DIR}" 2>&1)
    local status=$?

    assertEquals "set_platform_repo should return 0 on success" 0 "${status}"
    assertContains "Log should indicate successful setup" "${output_log}" "Build environment successfully set for myproduct-userdebug"
    assertContains "Log should show lunch target" "${output_log}" "myproduct-userdebug"
    # Check if vars set by mock lunch are present
    # Need to run this in a subshell to check env vars set by sourcing.
    local subshell_output
    subshell_output=$( (set_platform_repo "aproduct" "eng" "${MOCK_PLATFORM_DIR}" >/dev/null 2>&1 && echo "TARGET_PRODUCT=${TARGET_PRODUCT:-unset}") )
    assertContains "TARGET_PRODUCT should be set by mock lunch" "${subshell_output}" "TARGET_PRODUCT=aproduct"
}

test_set_platform_repo_lunch_fails() {
    mkdir -p "${TEST_TEMP_DIR}/bin" # For repo mock
    cat > "${TEST_TEMP_DIR}/bin/repo" <<-EOF
#!/bin/sh
if [ "\$1" = "list" ] && [ "\$2" = "-p" ]; then echo "build/make"; exit 0; fi
if [ "\$1" = "list" ]; then exit 0; fi
exit 1
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/repo"
    PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    local err_log
    # Mock lunch in MOCK_PLATFORM_DIR/build/envsetup.sh will fail if target contains "error"
    err_log=$(set_platform_repo "product_error" "userdebug" "${MOCK_PLATFORM_DIR}" 2>&1 >/dev/null)
    local status=$?
    assertEquals "set_platform_repo should fail if lunch fails" 1 "${status}"
    assertContains "Log should indicate lunch failed" "${err_log}" "'lunch product_error-userdebug' failed"
}

# Test parse_ab_url
test_parse_ab_url_full_url() {
    local branch target id
    parse_ab_url "ab://my-branch/my-target/12345" branch target id
    local status=$?
    assertEquals "parse_ab_url for full URL should succeed" 0 "${status}"
    assertEquals "Branch not parsed correctly" "my-branch" "${branch}"
    assertEquals "Target not parsed correctly" "my-target" "${target}"
    assertEquals "ID not parsed correctly" "12345" "${id}"
}

test_parse_ab_url_no_id() {
    local branch target id
    local warn_output
    parse_ab_url "ab://another-branch/another-target" branch target id 2>/dev/null
    local status=$?
    assertEquals "parse_ab_url with no ID should succeed" 0 "${status}"
    assertEquals "ID should default to 'latest' when missing" "latest" "${id}"
}

test_parse_ab_url_invalid_prefix() {
    local branch="" target="" id="" # Initialize to check they are not set
    local err_log
    err_log=$(parse_ab_url "http://my-branch/my-target/123" branch target id 2>&1 >/dev/null)
    local status=$?
    assertEquals "parse_ab_url with invalid prefix should fail" 1 "${status}"
    assertContains "Error log for invalid prefix" "${err_log}" "Invalid ab URL format"
    assertEquals "Branch should remain empty on failure" "" "${branch}"
}

# Test run_command
test_run_command_success() {
    local output_log
    output_log=$(run_command true 2>&1)
    local status=$?
    assertEquals "run_command with 'true' should return 0" 0 "${status}"
    assertContains "Log for successful run_command" "${output_log}" "Succeeded."
}

test_run_command_failure() {
    local output_log
    output_log=$(run_command false 2>&1)
    local status=$?
    assertEquals "run_command with 'false' should return 1" 1 "${status}"
    assertContains "Log for failed run_command" "${output_log}" "Failed."
    assertContains "Log for failed run_command should show exit code" "${output_log}" "Exit Code 1"
}

# Test set_env_var
test_set_env_var_success() {
    set_env_var "MY_TEST_VAR" "my_value" >/dev/null
    local status=$?
    assertEquals "set_env_var should return 0 on success" 0 "${status}"
    assertEquals "Environment variable MY_TEST_VAR set correctly" "my_value" "${MY_TEST_VAR:-}"
}

test_set_env_var_invalid_name() {
    local err_log
    err_log=$(set_env_var "1INVALID_VAR" "value" 2>&1 >/dev/null)
    local status=$?
    assertEquals "set_env_var with invalid name should return 1" 1 "${status}"
    assertContains "Error log for invalid name" "${err_log}" "Invalid environment variable name"
    # Check that the invalid variable was not actually set
    assertFalse "Invalid variable 1INVALID_VAR should not be set" "printenv | grep -q '^1INVALID_VAR='"
}

# --- Load shunit2 ---
if [[ ! -f "${SHUNIT2_PATH}" ]]; then
    echo "FATAL ERROR: Cannot find required library '$SHUNIT2_PATH'" >&2
    exit 1
fi

if ! . "${SHUNIT2_PATH}"; then
    echo "FATAL ERROR: Failed to source library '$SHUNIT2_PATH'. Check common_lib.sh dependencies." >&2
    exit 1
fi
