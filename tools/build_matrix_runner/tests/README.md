# Shell tests for `build_matrix_runner.sh`

These drive the runner end to end inside a sandbox where `launch_cvd.sh`,
`flash_device.sh`, `run_test_only.sh`, `adb`, `acloud` and `pontis` are all
stubs. Nothing reaches a real device, a real build or the cloud.

Tests for the scripts the runner calls live in
[`../../tests/`](../../tests/); the shared harness and the sandbox builder come
from there too.

## Running them

```bash
cd kernel/tests/tools/build_matrix_runner

make test          # shell suites + the Python reporter tests
make test-sh       # shell suites only (no venv needed)
make test-fast     # skip the cases that wait for real timeouts
make test-one T=cleanup
```

Or directly:

```bash
tests/run_all.sh
bash tests/device_cleanup_test.sh
```

## Suites

| File | What it protects |
| :--- | :--- |
| `launch_timeout_test.sh` | launch and flash deadlines fire, and a killed launch takes its whole process group with it |
| `atest_log_parse_test.sh` | a missing "Test logs:" line degrades the job instead of aborting the run and leaking a device |
| `device_cleanup_test.sh` | only instances this run created are deleted, and `acloud delete --all` is never issued |

`device_cleanup_test.sh` is the one to keep green. The scenarios in it come
from a real incident where somebody else's Cuttlefish instance was deleted.

## Note on `atest_log_parse_test.sh`

Its last section patches the *sandbox copy* of the runner back to the pre-fix
code to prove the old behaviour really did abort. If that line is ever
reworded, the patch stops applying and the section skips with a message rather
than reporting a phantom failure. Update the snippet in the test when that
happens.
