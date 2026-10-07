# Shell tests for `kernel/tests/tools`

Tests for the scripts that live one directory up: `common_lib.sh`,
`lib/device_util.sh`, `launch_cvd.sh` and the device-detection helpers in
`flash_device.sh`.

Tests for `mixed_build_test_runner.sh` itself live in
[`../mixed_build_test_runner/tests/`](../mixed_build_test_runner/tests/).

## Running them

```bash
cd kernel/tests/tools

make test                  # everything
make test-fast             # skip the cases that wait for real timeouts
make test-one T=device_util   # only suites matching 'device_util'
make test-all              # also runs the mixed_build_test_runner suites
```

Or directly:

```bash
tests/run_all.sh
SKIP_SLOW=1 tests/run_all.sh
bash tests/device_util_test.sh
```

Nothing here touches a real device, a real build or the cloud. Every external
binary (`adb`, `fastboot`, `pontis`, `acloud`, `repo`) is replaced by a stub.

## Layout

| Path | Contents |
| :--- | :--- |
| `common_lib_test.sh` | shunit2 suite for `common_lib.sh` |
| `device_util_test.sh` | Pontis resolution, transport probing, `device_util::init` |
| `launch_cvd_test.sh` | `ACLOUD_BOOT_TIMEOUT_SECS`, `--report-file` |
| `run_with_timeout_test.sh` | exit codes, process-group kill, terminal job control |
| `wait_for_condition_test.sh` | `duration_to_seconds`, `wait_for_condition`, init wait budget |
| `lib/test_common.sh` | shared `check` / `check_range` / skip helpers |
| `fixtures/` | stub binaries and the sandbox builder |

## Two frameworks, on purpose (for now)

`common_lib_test.sh` uses **shunit2** (`external/shflags/lib/shunit2`), which is
the framework this repository already had.

Everything else uses the lightweight harness in `lib/test_common.sh`. Those
suites grew out of debugging sessions and were adopted as regression tests
as-is; porting them to shunit2 is tracked as follow-up work in
[`../mixed_build_test_runner/HANDOFF.md`](../mixed_build_test_runner/HANDOFF.md).

**New tests should prefer shunit2.**

## Conventions

* One suite per unit under test, named `<unit>_test.sh`.
* No absolute paths. Resolve everything from `${BASH_SOURCE[0]}`.
* No writes inside the source tree: use `mktemp -d` and clean up with `trap`.
* A test that needs an unavailable tool calls `require_cmd` and skips, rather
  than failing.
* A case that spends more than a couple of seconds waiting for a real timeout
  goes behind `slow_enabled`, so `SKIP_SLOW=1` stays useful.
* Fixtures use obviously fake identifiers (serials, hostnames, ports). Never
  paste a real device serial into a test, even though nothing talks to it.

## Writing a new suite

```bash
#!/usr/bin/env bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(dirname "${TESTS_DIR}")"
source "${TESTS_DIR}/lib/test_common.sh"

section "what is being tested"
check "a description of the property" "expected" "$(thing_under_test)"

finish_tests
```
