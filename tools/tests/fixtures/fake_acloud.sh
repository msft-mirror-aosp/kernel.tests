#!/usr/bin/env bash
# Stand-in for the real acloud binary used by the launch_cvd.sh tests.
#
# Behaviour is driven entirely by environment variables so a test can ask for a
# success, a clean failure (acloud writes a report), or a hang (so an outside
# timeout has something to kill).
#
#   FAKE_ACLOUD_ARGV_FILE : argv is written here, one argument per line.
#   FAKE_ACLOUD_MODE      : success | bootfail | hang     (default success)
#   FAKE_ACLOUD_SLEEP     : seconds to sleep in 'hang' mode (default 600)
#   FAKE_ACLOUD_SERIAL    : device serial reported on success
#   FAKE_ACLOUD_INSTANCE  : instance name placed in the report

set -u

ARGV_FILE="${FAKE_ACLOUD_ARGV_FILE:-}"
MODE="${FAKE_ACLOUD_MODE:-success}"
SERIAL="${FAKE_ACLOUD_SERIAL:-127.0.0.1:6520}"
INSTANCE="${FAKE_ACLOUD_INSTANCE:-ins-fake0001-99999999-aosp-cf-x86-64-only-phone}"

if [[ -n "$ARGV_FILE" ]]; then
    printf '%s\n' "$@" > "$ARGV_FILE"
fi

# Pull --report-file out of argv; acloud accepts the separated form only.
report_file=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--report-file" ]]; then
        report_file="$arg"
    fi
    prev="$arg"
done

case "$MODE" in
    hang)
        # Never writes a report: this models acloud wedged inside create.Run(),
        # which is exactly when Dump() is never reached.
        sleep "${FAKE_ACLOUD_SLEEP:-600}"
        exit 0
        ;;
    bootfail)
        if [[ -n "$report_file" ]]; then
            cat > "$report_file" <<EOF
{
  "command": "create",
  "data": {
    "devices_failing_boot": [
      {
        "instance_name": "$INSTANCE",
        "ip": "10.0.0.1"
      }
    ]
  },
  "errors": ["Device did not finish on boot within timeout(1200 secs)"],
  "error_type": "ACLOUD_BOOT_UP_ERROR",
  "status": "BOOT_FAIL"
}
EOF
        fi
        exit 3
        ;;
    *)
        if [[ -n "$report_file" ]]; then
            cat > "$report_file" <<EOF
{
  "command": "create",
  "data": {
    "devices": [
      {
        "instance_name": "$INSTANCE",
        "ip": "10.0.0.1",
        "device_serial": "$SERIAL"
      }
    ]
  },
  "errors": [],
  "status": "SUCCESS"
}
EOF
        fi
        exit 0
        ;;
esac
