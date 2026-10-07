# Matrix Reporter

`matrix-reporter` is the Python-based data processing and visualization engine used by the `mixed_build_test_runner`.

While the main bash script (`mixed_build_test_runner.sh`) handles device provisioning and running the actual tests, this module is strictly responsible for parsing the resulting ATest JSON logs, aggregating the data, and generating the final Terminal, HTML, CSV, and Markdown reports.

You can use this tool as a standalone CLI to **manually regenerate reports** from raw logs without needing to rerun the tests.

---

## 1. Setup

This module runs in an isolated Python Virtual Environment to avoid dependency conflicts. The setup process is fully automated by the parent directory's Makefile.

To install it, simply go to the parent directory (`mixed_build_test_runner`) and run:
```bash
make setup
```

This will create a `venv/` folder inside this `reporter/` directory and install the `matrix-reporter` CLI inside it.

---

## 2. CLI Usage

Once the environment is set up, you can invoke the reporter manually. This is very useful if you accidentally deleted a report or want to regenerate an HTML/CSV/Markdown file from old test logs.

### Basic Syntax

```bash
./venv/bin/matrix-reporter --report-dir <DIRECTORY> [OPTIONS]
```

### Options

| Option | Description |
| :--- | :--- |
| `--report-dir <DIR>` | **[Required]** The path to the specific run directory containing the raw ATest logs. (e.g., `../reports/run_20260905_120000`). |
| `--config <FILE>` | **[Optional]** The path to the JSON matrix config used for the run. If provided, the reporter uses it to display human-readable names (e.g. "LTP on CF") instead of raw job IDs. |
| `--max-rows <INT>` | **[Optional]** The maximum number of test cases to print in your terminal. If the total tests exceed this number, the terminal will only show the *failed* tests to save screen space. (Default: 30) |

---

## 3. Example Scenario: Regenerating a Report

Imagine you ran a test matrix yesterday. The raw logs were saved in `../reports/run_yesterday`, but you lost the `matrix_report.html` file.

Instead of waiting hours for the devices to run the tests again, you can instantly rebuild the report by pointing the reporter to the folder:

```bash
# Ensure you are inside the reporter directory
cd reporter

# Regenerate the HTML, CSV, and Markdown reports using the raw logs and the original config
./venv/bin/matrix-reporter \
    --report-dir ../reports/run_yesterday \
    --config ../configs/local_ltp.json
```

---

## 4. Development & Contributing

If you want to modify how the HTML looks (in `templates/matrix_report.html.j2`) or change the Python parsing logic (`src/matrix_reporter/`), please ensure your code passes all checks before submitting a CL.

All development commands should be executed from the **parent directory** (`mixed_build_test_runner/`):

```bash
# Auto-format code
make format

# Run linter
make lint

# Run static type checking
make typecheck

# Run unit tests
make test
```
