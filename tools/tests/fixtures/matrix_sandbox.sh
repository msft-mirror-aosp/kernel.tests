#!/usr/bin/env bash
# Builds a throwaway copy of kernel/tests/tools where every external command
# is a stub, so mixed_build_test_runner.sh can be driven end to end without
# touching a real device or the cloud.
#
# Usage: source this file, then call make_sandbox <dir>.
#
# Layout created under <dir>:
#   tools/                          real common_lib.sh and lib/device_util.sh
#   tools/launch_cvd.sh             stub, behaviour from LAUNCH_STUB_MODE
#   tools/flash_device.sh           stub, behaviour from FLASH_STUB_MODE
#   tools/run_test_only.sh          stub, always reports a passing run
#   tools/mixed_build_test_runner/  the script under test
#   bin/                            stubs for adb, acloud, pontis (put on PATH)
#   state/                          scratch space the stubs write to

# The caller must export TOOLS_DIR (kernel/tests/tools).
REAL_TOOLS="${TOOLS_DIR:?matrix_sandbox.sh needs TOOLS_DIR}"

function make_sandbox() {
    local root="$1"
    rm -rf "$root"
    mkdir -p "$root/tools/lib" "$root/tools/mixed_build_test_runner" \
             "$root/bin" "$root/state"

    cp "$REAL_TOOLS/common_lib.sh" "$root/tools/"
    cp "$REAL_TOOLS/lib/device_util.sh" "$root/tools/lib/"
    cp "$REAL_TOOLS/mixed_build_test_runner/mixed_build_test_runner.sh" \
       "$root/tools/mixed_build_test_runner/"
    chmod +x "$root/tools/mixed_build_test_runner/mixed_build_test_runner.sh"

    # --- launch_cvd.sh stub -------------------------------------------------
    # 'hang' starts a grandchild too, so a test can prove the timeout kills the
    # whole process group and not just the script it launched.
    cat > "$root/tools/launch_cvd.sh" <<'STUB'
#!/usr/bin/env bash
set -u
STATE="${STUB_STATE_DIR:?}"
MODE="${LAUNCH_STUB_MODE:-success}"
SERIAL_OUT=""
REPORT_OUT=""
prev=""
for a in "$@"; do
    case "$prev" in
        -so|--serial-out) SERIAL_OUT="$a" ;;
        -rf|--report-file) REPORT_OUT="$a" ;;
    esac
    prev="$a"
done
echo "$@" >> "$STATE/launch_argv.log"
echo "launch_cvd stub: mode=$MODE"

# Model acloud creating the remote instance. This happens before anything can
# fail, which is why a killed launch leaves an instance behind with no report.
if [[ -n "${STUB_NEW_INSTANCE:-}" ]]; then
    echo "$STUB_NEW_INSTANCE" >> "$STATE/acloud_instances"
fi
# Somebody else starting a device in another terminal while we launch. It is
# not ours, whatever its build id says.
if [[ -n "${STUB_CONCURRENT_INSTANCE:-}" ]]; then
    echo "$STUB_CONCURRENT_INSTANCE" >> "$STATE/acloud_instances"
fi

function write_report() {
    local status="$1" key="$2"
    [[ -z "$REPORT_OUT" ]] && return 0
    mkdir -p "$(dirname "$REPORT_OUT")"
    cat > "$REPORT_OUT" <<EOF
{"command":"create","status":"$status","errors":[],
 "data":{"$key":[{"instance_name":"${STUB_INSTANCE:-ins-stub01-16407304-target}",
                  "device_serial":"${STUB_SERIAL:-127.0.0.1:6520}"}]}}
EOF
}

case "$MODE" in
    hang)
        # A grandchild in the same process group, like acloud's ssh.
        sleep 3000 &
        echo "$!" > "$STATE/launch_grandchild.pid"
        sleep 3000
        ;;
    bootfail)
        # acloud stopped on its own, so it managed to write a report.
        write_report BOOT_FAIL devices_failing_boot
        exit 3
        ;;
    plainfail)
        exit 1
        ;;
    emptyserial)
        write_report SUCCESS devices
        : > "$SERIAL_OUT"
        exit 0
        ;;
    *)
        write_report SUCCESS devices
        [[ -n "$SERIAL_OUT" ]] && echo "${STUB_SERIAL:-127.0.0.1:6520}" > "$SERIAL_OUT"
        exit 0
        ;;
esac
STUB

    # --- flash_device.sh stub ----------------------------------------------
    cat > "$root/tools/flash_device.sh" <<'STUB'
#!/usr/bin/env bash
set -u
case "${FLASH_STUB_MODE:-success}" in
    hang) sleep 3000 ;;
    fail) exit 1 ;;
    *)    echo "flash stub ok"; exit 0 ;;
esac
STUB

    # --- run_test_only.sh stub ---------------------------------------------
    # TEST_STUB_MODE picks the behaviour:
    #   success   passes and prints a log path (the default)
    #   nologline passes but prints no log path, like an atest that died early
    #   crash     fails with no log path and no result counts
    #   hang      never returns, to exercise the test timeout
    cat > "$root/tools/run_test_only.sh" <<'STUB'
#!/usr/bin/env bash
set -u
MODE="${TEST_STUB_MODE:-success}"
case "$MODE" in
    hang)
        sleep 3000
        ;;
    crash)
        echo "atest: some internal error" >&2
        exit 1
        ;;
    nologline)
        echo "Passed: 1, Failed: 0"
        exit 0
        ;;
    *)
        echo "Passed: 1, Failed: 0"
        # Must be a real readable directory, because the runner copies it.
        LOGDIR="${STUB_STATE_DIR:?}/atest_logs/log"
        mkdir -p "$LOGDIR"
        echo "stub" > "${LOGDIR%/log}/result.txt"
        echo "Test logs: ${LOGDIR}"
        exit 0
        ;;
esac
STUB

    # --- adb stub -----------------------------------------------------------
    # Only the subcommands device_util.sh actually uses.
    cat > "$root/bin/adb" <<'STUB'
#!/usr/bin/env bash
set -u
STATE="${STUB_STATE_DIR:?}"
case "${1:-}" in
    devices)
        echo "List of devices attached"
        if [[ -f "$STATE/adb_devices" ]]; then cat "$STATE/adb_devices"; fi
        ;;
    wait-for-device) exit 0 ;;
    -s)
        # 'adb -s <serial> <cmd>'
        case "${3:-}" in
            get-state) echo "device" ;;
            shell)     echo "" ;;
            *)         echo "" ;;
        esac
        ;;
    *) echo "" ;;
esac
exit 0
STUB

    # --- acloud stub --------------------------------------------------------
    cat > "$root/bin/acloud" <<'STUB'
#!/usr/bin/env bash
set -u
STATE="${STUB_STATE_DIR:?}"
echo "acloud $*" >> "$STATE/acloud.log"
case "${1:-}" in
    list)
        if [[ -f "$STATE/acloud_instances" ]]; then
            n=0
            while read -r name; do
                [[ -z "$name" ]] && continue
                n=$(( n + 1 ))
                echo "[$n]device serial: 127.0.0.1:$(( 6520 + n )) cvd-1 ($name) elapsed time: 0:05:00"
            done < "$STATE/acloud_instances"
        fi
        ;;
    delete)
        if [[ "${ACLOUD_DELETE_STUB_MODE:-ok}" == "hang" ]]; then sleep 3000; fi
        if [[ "${ACLOUD_DELETE_STUB_MODE:-ok}" == "explode" ]]; then
            echo "acloud.errors.GetGceZoneError: Can't get zone" >&2
            exit 157
        fi
        ;;
esac
exit 0
STUB

    # --- pontis stub --------------------------------------------------------
    # No bridged devices: keeps device_util.sh on its plain adb path.
    cat > "$root/bin/pontis" <<'STUB'
#!/usr/bin/env bash
printf 'BRIDGE\tID\tTYPE\tPORT\n'
exit 0
STUB

    chmod +x "$root/tools/launch_cvd.sh" "$root/tools/flash_device.sh" \
             "$root/tools/run_test_only.sh" "$root/bin/"*
}

# Writes a one job matrix config.
#   make_config <path> <device_type> [extra global_config json]
function make_config() {
    local path="$1" device_type="$2" extra="${3:-}"
    local extra_line=""
    [[ -n "$extra" ]] && extra_line="    ${extra},"
    cat > "$path" <<EOF
{
  "global_config": {
${extra_line}
    "test_suite": "dummy_suite"
  },
  "jobs": [
    {
      "job_id": "job_one",
      "display_name": "Job One",
      "device_type": "${device_type}",
      "serial_port": "127.0.0.1:6520",
      "builds": {
        "pb": {
          "branch": "git_main",
          "target": "aosp_cf_x86_64_only_phone-trunk_staging-userdebug",
          "build_id": "16407304"
        }
      }
    }
  ]
}
EOF
}
