# VTS LTP Build Matrix Runner

`build_matrix_runner` is an automated orchestration tool designed to run ATest test suites (such as VTS LTP) across a matrix of different Android builds. It supports both **Cuttlefish (Virtual Devices)** and **Physical Devices**, manages device provisioning/teardown automatically, features a robust auto-resume system, and generates beautiful HTML and CSV test reports.

---

## Quick Start

1. **Initialize Android Environment**:
   Before running the script, make sure you have initialized your Android build environment:
   ```bash
   source build/envsetup.sh
   lunch aosp_cf_x86_64_only_phone-trunk_staging-userdebug
   ```

2. **Setup Python Reporter Environment (One-time setup)**:
   The tool uses a Python module to generate beautiful HTML and CSV reports. You must install its dependencies first:
   ```bash
   make setup
   ```

3. **Run a basic matrix test**:
   Pass your matrix configuration JSON file using the `-c` flag.
   ```bash
   ./build_matrix_runner.sh -c configs/ltp.json
   ```

4. **Run and reuse the same virtual device**:
   If you are testing locally and want to save time launching and deleting Cuttlefish, you can tell the script to reuse the device across jobs.
   ```bash
   ./build_matrix_runner.sh -c configs/ltp.json --reuse-device
   ```

---

## Configuration File (JSON)

The tool relies on a JSON configuration file to define the execution matrix. You can generate a template config by running:
```bash
./build_matrix_runner.sh --generate-config > my_matrix.json
```

A standard configuration looks like this:
```json
{
  "global_config": {
    "test_suite": "vts_ltp_test_x86_64",
    "flash_timeout": "30m",
    "test_timeout": "3h",
    "device_wait_timeout": "3m"
  },
  "jobs": [
    {
      "job_id": "cf_mainline",
      "display_name": "LTP on CF (mainline)",
      "device_type": "virtual",
      "builds": {
        "pb": {
          "branch": "git_main",
          "target": "aosp_cf_x86_64_only_phone-trunk_staging-userdebug",
          "build_id": "latest"
        },
        "kb": {
          "branch": "aosp_kernel-common-android-mainline",
          "target": "kernel_virt_x86_64",
          "build_id": "latest"
        }
      }
    }
  ]
}
```
* **`device_type`**: Must be `"virtual"` (Cuttlefish) or `"physical"`.
* **`builds`**: Defines the artifacts to fetch (`pb`: Platform Build, `kb`: Kernel Build, `vkb`: Vendor Kernel Build, `sb`: System Build).
* **`flash_timeout`** *(optional, default `30m`)*: Upper bound on a single job's
  provisioning step.
* **`test_timeout`** *(optional, default `3h`)*: Upper bound on a single job's
  ATest run.
* **`device_wait_timeout`** *(optional, default `3m`)*: How long to keep looking
  for the device after it has been flashed and rebooted, before giving up on the
  job.

All three accept GNU `timeout` duration strings (`90s`, `45m`, `2h`) and can also
be overridden per-invocation via the `DEFAULT_FLASH_TIMEOUT`,
`DEFAULT_TEST_TIMEOUT` and `DEFAULT_DEVICE_WAIT_TIMEOUT` environment variables.
The polling interval used while waiting comes from
`DEFAULT_DEVICE_POLL_INTERVAL` (default `5s`).

> `flash_timeout` and `test_timeout` are **safety nets**, not normal-path
> budgets. Their job is to stop one wedged device from consuming an entire
> overnight matrix run — which matters a lot when every job in the matrix shares
> the same physical device. Don't tune them down aggressively: a healthy
> cold-cache flash can legitimately take tens of minutes because of the artifact
> download. Genuine hangs are caught in seconds by the per-command timeouts
> inside `flash_device.sh`.

> `device_wait_timeout` is different: it is a **tolerance window**, not a kill
> switch. A device bridged over the network (Pontis) routinely disappears for
> tens of seconds after a reboot while the bridge reconnects. Without this
> window the job fails instantly even though the device is about to come back.
> Raise it if your bridge is slow; lowering it below roughly a minute mostly
> just makes the runner fragile.

---

## Smart State Management (3-State Model)

The script tracks the outcome of every job and categorizes them into three distinct states:
1. **`SUCCESS`**: The device launched, tests ran, and **0** test cases failed.
2. **`COMPLETED_WITH_FAILURES`**: The device launched and tests ran successfully, but **some test cases failed**. *(Note: This is a normal outcome indicating a regression was caught, not a script crash).*
3. **`ERROR`**: The infrastructure crashed (e.g., Cuttlefish failed to boot, ADB disconnected, ATest crashed).

---

## Command-Line Options

### General Execution
| Flag | Description |
| :--- | :--- |
| `-c, --config <file>` | **[Required]** Path to your JSON matrix configuration file. |
| `-od, --output-dir <dir>` | Directory to save logs and reports. (Default: `reports/`) |
| `-j, --job-id <id>` | Run **only** the specific job matching this ID from the JSON. |
| `-t, --test <suite>` | Override the test suite specified in the JSON config. |
| `-s, --serial-number <sn>` | Override the serial number (ADB port) for physical devices. |
| `--dry-run` | Print the jobs that would be executed without actually launching devices or running tests. |
| `--fail-fast` | Immediately abort the matrix run if any job encounters an **`ERROR`** (crashes). Jobs with `COMPLETED_WITH_FAILURES` will **not** trigger the abort. |

### Device Management
| Flag | Description |
| :--- | :--- |
| `--keep-device`<br>`--no-teardown` | Do not delete the virtual device after the job finishes. Useful for manual debugging after a run. |
| `--reuse-device` | Look for an existing, running virtual device from a previous job and reuse it instead of launching a new one. **Implies `--keep-device`**. This massively speeds up testing on the same machine. |
| `--skip-initial-flash` | Skip the physical device flashing step (`flash_device.sh`) **only** for the first physical job in the queue. Extremely useful when resuming a matrix on a device that is already flashed. |

---

## Resuming Interrupted Runs

If your machine restarts or a job crashes midway (e.g., Cuttlefish fails to boot), you do not need to start over! The runner uses a `.run_state_<config>` file in the `out/` directory to track progress.

> **IMPORTANT**: `--resume` and `--resume-from` are **mutually exclusive**. Do not use them together.

### 1. The Auto-Resume (`--resume`)
The smartest and most common way to recover.
```bash
./build_matrix_runner.sh -c configs/ltp.json --resume
```
* **What it does**: It reads the state file and groups logs under the original `RUN_ID`.
* **Skipping logic**: It will **skip** any job marked as `SUCCESS` or `COMPLETED_WITH_FAILURES` (since we already have their reports). It will automatically retry jobs marked as `ERROR` and continue to the unexecuted jobs.

### 2. Manual Resume (`--resume-from <job_id>`)
Use this when you want to forcefully dictate where to restart.
```bash
./build_matrix_runner.sh -c configs/ltp.json --resume-from cf_15_6_6
```
* **What it does**: It skips all jobs preceding the specified `job_id` and begins execution exactly at that job.
* **Pre-flight Safety**: To prevent generating incomplete "ghost" reports, the script will strictly verify that all jobs preceding your target were completed (either `SUCCESS` or `COMPLETED_WITH_FAILURES`). If an earlier job was skipped or had an `ERROR`, the script will abort and warn you.

### How to reset a run?
If you want to start completely fresh and wipe the old state, simply run the script **without** `--resume` or `--resume-from`. The tool will safely truncate the previous state file and start a brand new run.

---

## Reports

When the matrix finishes, the python-based `matrix-reporter` generates the results inside `reports/<RUN_ID>/`:
1. **`matrix_report.html`**: A highly visual, interactive HTML dashboard comparing test results side-by-side across all builds.
2. **`matrix_report.csv`**: A spreadsheet-friendly CSV containing the Detailed Test Matrix, perfect for importing into Excel or Google Spreadsheets for filtering and pivot tables.
3. **`matrix_report.md`**: A GitHub-flavored Markdown table containing the Detailed Test Matrix, ideal for sharing in bug reports, documents, and code reviews.
4. **Raw Logs**: Individual ATest logs for each job are stored in their respective subdirectories.

*(If the reporter fails to run, ensure you have set up the Python virtual environment by running `make setup` in the root directory).*
