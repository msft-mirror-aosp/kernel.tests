#!/usr/bin/env bash
# Tests for launch_cvd.sh, driven against a fake acloud binary so nothing
# reaches the cloud, from inside a throwaway repo root so nothing depends on
# the checkout the tests happen to live in.
#
# Two areas, merged from earlier ad-hoc scripts:
#
#  1. ACLOUD_BOOT_TIMEOUT_SECS. The contract is deliberately narrow: without
#     the variable the command line must be byte for byte what it was before
#     the knob existed, because acloud already enforces its own boot budget.
#
#  2. --report-file. The report has to survive a failed launch, because that is
#     the only way the caller can learn which instance to delete.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(dirname "${TESTS_DIR}")"
# shellcheck source=lib/test_common.sh
source "${TESTS_DIR}/lib/test_common.sh"

# launch_cvd.sh refuses to start unless every one of its REQUIRED_COMMANDS is
# present; adb and bc are the two a bare machine may lack.
require_cmd jq adb bc

LAUNCH_CVD="${TOOLS_DIR}/launch_cvd.sh"
FAKE_ACLOUD="${TESTS_DIR}/fixtures/fake_acloud.sh"
PB="ab://git_main/aosp_cf_x86_64_only_phone-trunk_staging-userdebug/16407304"
INSTANCE="ins-cccc3333-16407304-aosp-cf-x86-64-only-phone"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A throwaway repo root. launch_cvd.sh insists on locating a .repo directory
# before it does anything else: it asks 'repo list' whether $PWD is a
# workspace, falls back to its own directory, and exits 1 if neither has a
# .repo above it. Hand it one of our own and run from there, so the suite
# passes outside a checkout and never reads the manifest of whichever checkout
# it happens to live in. The stub only has to make 'repo list' succeed where a
# .repo directory exists.
REPO_ROOT="${WORK}/repo"
mkdir -p "${REPO_ROOT}/.repo" "${WORK}/bin"
cat > "${WORK}/bin/repo" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "list" && -d .repo ]]
STUB
chmod +x "${WORK}/bin/repo"
export PATH="${WORK}/bin:${PATH}"
cd "$REPO_ROOT" || exit 1

# Runs launch_cvd.sh and echoes the argv the fake acloud received, on one line.
function run_launch() {
    local argv_file="${WORK}/argv.txt"
    rm -f "$argv_file"
    FAKE_ACLOUD_ARGV_FILE="$argv_file" \
        timeout 120 "$LAUNCH_CVD" --acloud-bin="$FAKE_ACLOUD" -pb "$PB" "$@" \
        > "${WORK}/stdout.txt" 2>&1
    echo "$?" > "${WORK}/rc.txt"
    if [[ -f "$argv_file" ]]; then
        tr '\n' ' ' < "$argv_file"
    fi
}

function count_flag() {
    grep -o -- '--boot-timeout' <<< "$1" | wc -l
}

function stdout_has() {
    grep -q -- "$1" "${WORK}/stdout.txt" && echo yes || echo no
}

# argv_value_after <argv_file> <flag> -- the argument that followed <flag> in an
# argv file written one argument per line.
function argv_value_after() {
    awk -v flag="$2" 'found { print; exit } $0 == flag { found = 1 }' "$1"
}

section "ACLOUD_BOOT_TIMEOUT_SECS: the default must not move"

argv=$(run_launch)
check "unset: no --boot-timeout is passed" "0" "$(count_flag "$argv")"
baseline_argv="$argv"

argv=$(ACLOUD_BOOT_TIMEOUT_SECS= run_launch)
check "an empty string behaves like unset" "0" "$(count_flag "$argv")"
check "an empty string produces the same command line" "$baseline_argv" "$argv"

section "ACLOUD_BOOT_TIMEOUT_SECS: explicit override"

argv=$(ACLOUD_BOOT_TIMEOUT_SECS=900 run_launch)
check "900 is forwarded" "yes" \
    "$([[ "$argv" == *"--boot-timeout 900 "* ]] && echo yes || echo no)"
check "900 is forwarded exactly once" "1" "$(count_flag "$argv")"

argv=$(ACLOUD_BOOT_TIMEOUT_SECS=0 run_launch)
check "0 is a real value, not treated as unset" "1" "$(count_flag "$argv")"

section "ACLOUD_BOOT_TIMEOUT_SECS: validation"

argv=$(ACLOUD_BOOT_TIMEOUT_SECS=20m run_launch)
check "a non-numeric value aborts before running acloud" "" "$argv"
check "a non-numeric value exits non-zero" "1" "$(cat "${WORK}/rc.txt")"
check "a non-numeric value explains itself" "yes" \
    "$(stdout_has 'must be a whole number of seconds')"

section "ACLOUD_BOOT_TIMEOUT_SECS: interaction with --acloud-arg"

argv=$(ACLOUD_BOOT_TIMEOUT_SECS=900 run_launch --acloud-arg=--boot-timeout=600)
check "a caller --boot-timeout=600 wins over the env var" "1" "$(count_flag "$argv")"
check "the caller value is the one that survives" "yes" \
    "$([[ "$argv" == *"--boot-timeout=600"* ]] && echo yes || echo no)"
check "the conflict is reported" "yes" \
    "$(stdout_has 'Ignoring ACLOUD_BOOT_TIMEOUT_SECS')"

argv=$(ACLOUD_BOOT_TIMEOUT_SECS=900 run_launch --acloud-arg=--boot-timeout --acloud-arg=600)
check "the separated caller form also wins" "1" "$(count_flag "$argv")"

# A flag that merely starts the same way must not look like --boot-timeout.
argv=$(ACLOUD_BOOT_TIMEOUT_SECS=900 run_launch --acloud-arg=--local-instance)
check "an unrelated acloud arg does not suppress the env var" "1" "$(count_flag "$argv")"
check "an unrelated acloud arg is preserved" "yes" \
    "$([[ "$argv" == *"--local-instance"* ]] && echo yes || echo no)"

section "--report-file"

# The report must survive a successful launch.
rm -f "$WORK/report.json" "$WORK/serial.txt"
FAKE_ACLOUD_MODE=success FAKE_ACLOUD_INSTANCE="$INSTANCE" \
    timeout 120 "$LAUNCH_CVD" --acloud-bin="$FAKE_ACLOUD" -pb "$PB" \
    -rf "$WORK/report.json" -so "$WORK/serial.txt" > "$WORK/out.txt" 2>&1
check "success: the report file is kept" "yes" \
    "$([[ -s "$WORK/report.json" ]] && echo yes || echo no)"
check "success: the report names the instance" "$INSTANCE" \
    "$(jq -r '.data.devices[0].instance_name' "$WORK/report.json" 2>/dev/null)"
check "success: the serial is still extracted" "127.0.0.1:6520" \
    "$(cat "$WORK/serial.txt" 2>/dev/null)"

# And it must survive a failed launch, which is the case that actually matters.
rm -f "$WORK/report.json" "$WORK/serial.txt"
FAKE_ACLOUD_MODE=bootfail FAKE_ACLOUD_INSTANCE="$INSTANCE" \
    timeout 120 "$LAUNCH_CVD" --acloud-bin="$FAKE_ACLOUD" -pb "$PB" \
    -rf "$WORK/report.json" -so "$WORK/serial.txt" > "$WORK/out.txt" 2>&1
check "boot failure: the report file is still kept" "yes" \
    "$([[ -s "$WORK/report.json" ]] && echo yes || echo no)"
check "boot failure: the instance name is recoverable" "$INSTANCE" \
    "$(jq -r '.data.devices_failing_boot[0].instance_name' "$WORK/report.json" 2>/dev/null)"
check "boot failure: no stale serial file is left" "no" \
    "$([[ -e "$WORK/serial.txt" ]] && echo yes || echo no)"

# A stale report from a previous run must not be mistaken for a new one.
echo '{"stale":true}' > "$WORK/report.json"
FAKE_ACLOUD_MODE=success FAKE_ACLOUD_INSTANCE="$INSTANCE" \
    timeout 120 "$LAUNCH_CVD" --acloud-bin="$FAKE_ACLOUD" -pb "$PB" \
    -rf "$WORK/report.json" > "$WORK/out.txt" 2>&1
check "a stale report is overwritten" "no" \
    "$(grep -q stale "$WORK/report.json" && echo yes || echo no)"

# Without -rf the old behaviour stands: a temporary report, removed afterwards.
# Give the script a private, empty TMPDIR so the assertion is about the one
# file it creates, not about whatever else is happening in /tmp, and learn that
# file's name from the argv the fake acloud recorded.
TMP_PRIVATE="${WORK}/tmpdir"
mkdir -p "$TMP_PRIVATE"
FAKE_ACLOUD_MODE=success FAKE_ACLOUD_ARGV_FILE="$WORK/argv_norf.txt" TMPDIR="$TMP_PRIVATE" \
    timeout 120 "$LAUNCH_CVD" --acloud-bin="$FAKE_ACLOUD" \
    -pb "$PB" -so "$WORK/serial2.txt" > "$WORK/out.txt" 2>&1
check "without -rf the serial still works" "127.0.0.1:6520" \
    "$(cat "$WORK/serial2.txt" 2>/dev/null)"
temp_report=$(argv_value_after "$WORK/argv_norf.txt" --report-file)
check "without -rf a temporary report in TMPDIR is used" "yes" \
    "$([[ "$temp_report" == "$TMP_PRIVATE"/* ]] && echo yes || echo "no: '$temp_report'")"
check "without -rf the temporary report is removed afterwards" "no" \
    "$([[ -n "$temp_report" && -e "$temp_report" ]] && echo yes || echo no)"
check "without -rf nothing else is left in TMPDIR" "" "$(ls -A "$TMP_PRIVATE")"

section "regressions on untouched behaviour"

rm -f "${WORK}/serial3.txt"
run_launch -so "${WORK}/serial3.txt" > /dev/null
check "-so still extracts the serial" "127.0.0.1:6520" \
    "$(cat "${WORK}/serial3.txt" 2>/dev/null)"

finish_tests
