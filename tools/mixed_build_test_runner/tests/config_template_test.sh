#!/usr/bin/env bash
# Tests for the config templates in configs/ and for --generate-config.
#
# This repository is mirrored to AOSP, so the templates must never carry a
# device serial, a pinned build id or an internal branch name. These checks
# keep that true, and keep --generate-config printing the templates rather than
# a copy of its own that drifts.
#
# Read-only: the runner is only invoked with --generate-config, which prints
# a file and exits before touching a device, a build or the cloud.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="$(dirname "${TESTS_DIR}")"
TOOLS_DIR="$(dirname "${RUNNER_DIR}")"
RUNNER="${RUNNER_DIR}/mixed_build_test_runner.sh"
CONFIGS_DIR="${RUNNER_DIR}/configs"
VIRTUAL_TEMPLATE="${CONFIGS_DIR}/ltp_virtual.template.json"
PHYSICAL_TEMPLATE="${CONFIGS_DIR}/ltp_physical.template.json"
SHUNIT2_PATH="${TOOLS_DIR}/../../../external/shflags/lib/shunit2"

TEMPLATES=()

oneTimeSetUp() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "FATAL ERROR: jq is required" >&2
        exit 1
    fi
    TEMPLATES=("${CONFIGS_DIR}"/*.template.json)
}

# Asserts that the jq filter evaluates to true for every template.
function assert_all_templates() {
    local message="$1" filter="$2" template
    for template in "${TEMPLATES[@]}"; do
        assertEquals "$(basename "$template"): $message" "true" \
            "$(jq -r "$filter" "$template" 2>&1)"
    done
}

test_both_templates_exist() {
    assertTrue "virtual template is missing" "[[ -f '$VIRTUAL_TEMPLATE' ]]"
    assertTrue "physical template is missing" "[[ -f '$PHYSICAL_TEMPLATE' ]]"
}

test_templates_are_valid_json() {
    local template
    for template in "${TEMPLATES[@]}"; do
        assertTrue "$(basename "$template") is not valid JSON" \
            "jq empty '$template'"
    done
}

test_templates_have_the_fields_the_runner_reads() {
    assert_all_templates "global_config.test_suite is set" \
        '(.global_config.test_suite // "") != ""'
    assert_all_templates "jobs is a non-empty list" \
        '(.jobs | type) == "array" and (.jobs | length) > 0'
    assert_all_templates "every job has a job_id" \
        'all(.jobs[]; (.job_id // "") != "")'
    assert_all_templates "every device_type is virtual or physical" \
        'all(.jobs[]; .device_type == "virtual" or .device_type == "physical")'
    assert_all_templates "every job has a platform build" \
        'all(.jobs[]; (.builds.pb.branch // "") != "" and (.builds.pb.target // "") != "")'
}

test_job_ids_are_unique() {
    assert_all_templates "job_ids are unique" \
        '([.jobs[].job_id] | length) == ([.jobs[].job_id] | unique | length)'
}

test_templates_never_pin_a_build_id() {
    assert_all_templates "every build_id is \"latest\"" \
        'all(.jobs[].builds[]; .build_id == "latest")'
}

test_templates_never_carry_a_serial() {
    assert_all_templates "serial_port is absent or empty" \
        'all(.jobs[]; (.serial_port // "") == "")'
}

test_physical_template_uses_placeholders_only() {
    # Device and vendor branch names are internal; the template must not name
    # a real one.
    assertEquals "physical template: every branch and target is a <PLACEHOLDER>" \
        "true" \
        "$(jq -r 'all(.jobs[].builds[] | .branch, .target; test("^<[A-Z0-9_]+>$"))' \
            "$PHYSICAL_TEMPLATE")"
}

test_physical_template_jobs_are_physical() {
    assertEquals "physical template: every job is physical" "true" \
        "$(jq -r 'all(.jobs[]; .device_type == "physical")' "$PHYSICAL_TEMPLATE")"
}

test_virtual_template_jobs_are_virtual() {
    assertEquals "virtual template: every job is virtual" "true" \
        "$(jq -r 'all(.jobs[]; .device_type == "virtual")' "$VIRTUAL_TEMPLATE")"
}

test_generate_config_defaults_to_virtual() {
    local out
    out="$("$RUNNER" --generate-config 2> /dev/null)"
    assertEquals "exit code" 0 $?
    assertEquals "prints the virtual template" "$(cat "$VIRTUAL_TEMPLATE")" "$out"
}

test_generate_config_virtual() {
    local out
    out="$("$RUNNER" --generate-config virtual 2> /dev/null)"
    assertEquals "exit code" 0 $?
    assertEquals "prints the virtual template" "$(cat "$VIRTUAL_TEMPLATE")" "$out"
}

test_generate_config_physical() {
    local out
    out="$("$RUNNER" --generate-config physical 2> /dev/null)"
    assertEquals "exit code" 0 $?
    assertEquals "prints the physical template" "$(cat "$PHYSICAL_TEMPLATE")" "$out"
}

test_generate_config_does_not_swallow_the_next_flag() {
    local out
    out="$("$RUNNER" --generate-config --dry-run 2> /dev/null)"
    assertEquals "exit code" 0 $?
    assertEquals "a following flag is not taken as the kind" \
        "$(cat "$VIRTUAL_TEMPLATE")" "$out"
}

test_generate_config_rejects_an_unknown_kind() {
    local out rc
    out="$("$RUNNER" --generate-config bogus 2> /dev/null)"
    rc=$?
    assertNotEquals "exit code" 0 "$rc"
    assertEquals "nothing on stdout, so a redirect does not produce a bad config" \
        "" "$out"
}

test_gitignore_tracks_only_templates() {
    if ! git -C "$RUNNER_DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        startSkipping
    fi
    # check-ignore works on paths that do not exist, so nothing is created.
    assertTrue "a local config is ignored" \
        "git -C '$RUNNER_DIR' check-ignore -q configs/local_example.json"
    assertTrue "any other non-template config is ignored" \
        "git -C '$RUNNER_DIR' check-ignore -q configs/my_matrix.json"
    assertFalse "a template is not ignored" \
        "git -C '$RUNNER_DIR' check-ignore -q configs/example.template.json"
}

# --- Load shunit2 ---
if [[ ! -f "${SHUNIT2_PATH}" ]]; then
    echo "FATAL ERROR: Cannot find required library '$SHUNIT2_PATH'" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "${SHUNIT2_PATH}"
