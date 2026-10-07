# Working on `build_matrix_runner`

Rules for anyone — human or agent — changing anything under
`kernel/tests/tools/`. This file is loaded automatically when you edit files in
this directory or below it.

User-facing documentation is in [README.md](README.md). This file is about how
to *work on* the code.

## Layout

| Path | What it is |
| :--- | :--- |
| `build_matrix_runner.sh` | the runner itself, plain bash |
| `configs/*.json` | matrix definitions |
| `reporter/` | Python package that renders the HTML report |
| `tests/` | shell suites for the runner |
| `../tests/` | shell suites for `common_lib.sh`, `device_util.sh`, `launch_cvd.sh`, `flash_device.sh` |
| `out/`, `reports/` | generated, gitignored |

The runner depends on scripts one level up. **A change to `common_lib.sh` or
`lib/device_util.sh` can break the runner without touching a single file in
this directory**, so run both test directories.

## Before you finish a change

```bash
cd kernel/tests/tools
make test-all        # both directories, ~3 minutes
```

While iterating, `make test-fast` skips the cases that wait for real timeouts.

For the Python reporter:

```bash
cd kernel/tests/tools/build_matrix_runner
make setup           # once
make lint typecheck test-py
```

## Conventions

* Shell tests go in a `tests/` directory, named `<unit>_test.sh`. Never beside
  the file under test.
* No absolute paths anywhere — not in scripts, not in tests, not in configs.
  Resolve from `${BASH_SOURCE[0]}`.
* Tests must not touch a real device, a real build or the cloud. Stub the
  external binary instead; `../tests/fixtures/matrix_sandbox.sh` already builds
  a full sandbox.
* Tests must not write inside the source tree. Use `mktemp -d` with a `trap`.
* New shell tests should prefer shunit2, matching `../tests/common_lib_test.sh`.
  The lightweight harness in `../tests/lib/test_common.sh` exists for the
  suites inherited from debugging sessions.

## Hazards worth knowing

* **Never widen a teardown.** `acloud delete --all` must never be issued, and
  an instance this run did not create must never be deleted. When ownership is
  ambiguous, delete nothing and tell the user. `tests/device_cleanup_test.sh`
  encodes a real incident where this went wrong.
* **Every external call needs a deadline.** Use `run_with_timeout`. A bare
  `fastboot getvar` against a bridged device can block forever.
* **Do not add `--foreground` to `run_with_timeout`.** It would stop the whole
  process group from being killed and leak grandchildren. The stdin redirect is
  deliberate; see `../tests/run_with_timeout_test.sh`.
* **A failing `grep` must not end a job.** The runner keeps going and reports
  per-job status; an unguarded pipeline once aborted the whole matrix and
  leaked a cloud instance.

## Keeping `HANDOFF.md` current

`HANDOFF.md` records **the current state of work in progress**, so the next
session can pick it up. It is deliberately not committed (see `.gitignore`);
the git history is the changelog, this file is not.

### Update it when any of these is true

1. You are about to run `git commit` in this tree.
2. The user says to stop, pause, or leave it for now.
3. You are leaving a failing test or a known bug behind.
4. You applied a workaround you know is not the real fix.
5. A refactor is part-done (e.g. 3 of 8 files converted).
6. A conclusion still needs verifying on real hardware or a real Cuttlefish.

### Do not update it when

* The work is finished, committed, and the tests are green.
* The conversation was read-only: questions, code reading, explanation.
* You only changed comments or formatting.

### How to write it

**Overwrite the file every time. Never append.** A log of past states is what
turned the previous version of this file into something nobody read. Keep it
under ~60 lines and keep the headings, writing `(none)` under any that is
empty, so the next reader knows it was actually considered.
