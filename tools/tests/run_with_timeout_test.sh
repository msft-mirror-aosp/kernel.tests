#!/usr/bin/env bash
# Tests for run_with_timeout() in common_lib.sh.
#
# Two things are covered here, merged from earlier ad-hoc scripts:
#
#  1. Plain semantics: exit codes pass through, a real timeout reports 124, and
#     the whole process group dies so a device is never left held.
#
#  2. Terminal job control. GNU timeout puts the child in a new process group,
#     which is not the terminal's foreground group. Anything in a background
#     group that reads the terminal gets SIGTTIN, and anything that calls
#     tcsetattr gets SIGTTOU. Both stop the whole group for good. 'ssh -t'
#     calls tcsetattr, which is exactly how acloud used to freeze at
#     "Launching AVD(s) and waiting for boot up".
#
# The job control cases run inside a real pty, because without a controlling
# terminal none of that can happen and the tests would pass for free.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(dirname "${TESTS_DIR}")"
# shellcheck source=lib/test_common.sh
source "${TESTS_DIR}/lib/test_common.sh"

PROBE="${TESTS_DIR}/fixtures/tcsetattr_probe.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=/dev/null
source "${TOOLS_DIR}/common_lib.sh" || {
    echo "cannot source common_lib.sh" >&2
    exit 1
}

section "exit code semantics"

run_with_timeout 5s true > /dev/null 2>&1
check "success passes through" "0" "$?"

run_with_timeout 5s bash -c 'exit 42' > /dev/null 2>&1
check "exit 42 passes through" "42" "$?"

run_with_timeout 1s sleep 30 > /dev/null 2>&1
check "a real timeout returns EXIT_TIMEOUT(124)" "124" "$?"

run_with_timeout "" true > /dev/null 2>&1
check "an empty duration is rejected" "1" "$?"

section "the whole process group is killed"

# If the timeout only killed the direct child, a grandchild would survive and
# keep holding whatever the command had open.
cat > "${WORK}/spawner.sh" <<'EOS'
#!/usr/bin/env bash
sleep 293 &
wait
EOS
chmod +x "${WORK}/spawner.sh"

run_with_timeout 1s "${WORK}/spawner.sh" > /dev/null 2>&1
sleep 1
if pgrep -x sleep -a 2>/dev/null | grep -q 293; then
    pkill -f "sleep 293" 2>/dev/null
    check "the grandchild is cleaned up" "yes" "no: it leaked"
else
    check "the grandchild is cleaned up" "yes" "yes"
fi

# ---------------------------------------------------------------------------
# Everything below needs a pty.
# ---------------------------------------------------------------------------
require_cmd script python3

# Runs a snippet with common_lib.sh loaded, inside a pty.
function in_pty() {
    local snippet="$1"
    script -qec "bash -c 'source \"${TOOLS_DIR}/common_lib.sh\"; ${snippet}'" \
        /dev/null 2>&1 | tr -d '\r'
}

section "the terminal cannot stop us any more"

# The heart of it. Before the fix this timed out instead of finishing.
out=$(in_pty "run_with_timeout 8s python3 ${PROBE}; echo rc=\$?")
check "a child that calls tcsetattr is not frozen" "yes" \
    "$(grep -q 'SURVIVED' <<< "$out" && echo yes || echo no)"
check "and it exits cleanly rather than timing out" "yes" \
    "$(grep -q 'rc=0' <<< "$out" && echo yes || echo no)"
check "the child sees no tty on stdin" "yes" \
    "$(grep -q 'stdin is not a tty' <<< "$out" && echo yes || echo no)"

# Proof that the pty harness is real: the same probe without the guard does
# freeze. If this ever starts passing, the test above proves nothing.
if slow_enabled; then
    out=$(in_pty "timeout 5s python3 ${PROBE}; echo rc=\$?")
    check "control: a bare timeout still freezes on a tty" "yes" \
        "$(grep -q 'rc=124' <<< "$out" && echo yes || echo no)"
else
    skip_test "control: a bare timeout still freezes on a tty" "SKIP_SLOW"
fi

# A child that reads stdin used to raise SIGTTIN and hang. Now it gets EOF.
out=$(in_pty "run_with_timeout 8s head -n 1; echo rc=\$?")
check "a child that reads stdin gets EOF instead of hanging" "yes" \
    "$(grep -q 'rc=0' <<< "$out" && echo yes || echo no)"

section "nothing else changed"

out=$(in_pty "run_with_timeout 8s echo hello; echo rc=\$?")
check "stdout still streams through" "yes" \
    "$(grep -q '^hello' <<< "$out" && echo yes || echo no)"
check "a successful command still returns 0" "yes" \
    "$(grep -q 'rc=0' <<< "$out" && echo yes || echo no)"

out=$(in_pty "v=\$(run_with_timeout 8s echo captured); echo got=[\$v]")
check "command substitution still captures the output" "yes" \
    "$(grep -q 'got=\[captured\]' <<< "$out" && echo yes || echo no)"

printf '#!/usr/bin/env bash\nexit 7\n' > "${WORK}/exit7.sh"
chmod +x "${WORK}/exit7.sh"
out=$(in_pty "run_with_timeout 8s ${WORK}/exit7.sh; echo rc=\$?")
check "an ordinary failure keeps its own exit code" "yes" \
    "$(grep -q 'rc=7' <<< "$out" && echo yes || echo no)"

out=$(in_pty "run_with_timeout 2s sleep 30; echo rc=\$?")
check "a real timeout is still reported inside a pty" "yes" \
    "$(grep -qE 'rc=124|Timed out after' <<< "$out" && echo yes || echo no)"

section "the process group is still killed inside a pty"

# This is the reason '--foreground' was rejected. If the stdin redirect had
# been swapped for '--foreground', the grandchild below would survive.
cat > "${WORK}/parent.sh" <<EOF
#!/usr/bin/env bash
sleep 300 &
echo "\$!" > "${WORK}/grandchild.pid"
sleep 300
EOF
chmod +x "${WORK}/parent.sh"

rm -f "${WORK}/grandchild.pid"
in_pty "run_with_timeout 3s ${WORK}/parent.sh; echo rc=\$?" > /dev/null
sleep 2
gpid=$(cat "${WORK}/grandchild.pid" 2>/dev/null || echo "")
check "a grandchild was actually started" "yes" \
    "$([[ -n "$gpid" ]] && echo yes || echo no)"
check "the grandchild is killed with the parent" "no" \
    "$(kill -0 "$gpid" 2>/dev/null && echo yes || echo no)"
[[ -n "$gpid" ]] && kill -9 "$gpid" 2>/dev/null

# Guard against somebody 'fixing' this with --foreground later. Comments are
# stripped first, because the ones above talk about it on purpose.
check "--foreground is not used in the implementation" "0" \
    "$(grep -v '^[[:space:]]*#' "${TOOLS_DIR}/common_lib.sh" | grep -c -- '--foreground')"

finish_tests
