import json
import logging
from pathlib import Path
from typing import Dict, List

from matrix_reporter.models import AtestResult, JobConfig, MatrixConfig, ParsedResult

logger = logging.getLogger(__name__)


def parse_config(config_path: Path) -> Dict[str, JobConfig]:
    """Parse e2e_matrix.json to extract job_id to JobConfig mapping."""
    job_configs: Dict[str, JobConfig] = {}
    if not config_path.exists():
        logger.warning(f"Config file not found at {config_path}")
        return job_configs

    try:
        data = json.loads(config_path.read_text())
        config = MatrixConfig.model_validate(data)
        for job in config.jobs:
            job_configs[job.job_id] = job
    except Exception as e:
        logger.error(f"Failed to parse config: {e}")
    return job_configs


def extract_crash_logs(job_dir: Path) -> str:
    """Extract last 30 lines from atest.log or runner_stdout.log if test_result is missing."""
    for log_name in ["atest.log", "runner_stdout.log"]:
        log_file = job_dir / log_name
        if log_file.exists():
            try:
                lines = log_file.read_text(errors="replace").splitlines()
                snippet = "\n".join(lines[-30:])
                return f"--- Last 30 lines of {log_name} ---\n{snippet}"
            except Exception as e:
                return f"Failed to read {log_name}: {e}"
    return "No test_result, atest.log, or runner_stdout.log found to diagnose the crash."


def extract_results(report_dir: Path) -> tuple[List[ParsedResult], Dict[str, str]]:
    """Walk through report_dir and parse test_result files. Return results and crash logs."""
    all_results: List[ParsedResult] = []
    crashes: Dict[str, str] = {}

    if not report_dir.exists() or not report_dir.is_dir():
        logger.error(f"Report directory {report_dir} is invalid.")
        return all_results, crashes

    for job_dir in report_dir.iterdir():
        if not job_dir.is_dir():
            continue

        job_id = job_dir.name
        test_result_file = job_dir / "test_result"

        if not test_result_file.exists():
            logger.warning(f"No test_result found in {job_dir}. Extracting crash logs.")
            crashes[job_id] = extract_crash_logs(job_dir)
            continue

        try:
            data = json.loads(test_result_file.read_text())
            atest_result = AtestResult.model_validate(data)

            if not atest_result.test_runner or not atest_result.test_runner.AtestTradefedTestRunner:
                # Might be a crash during Tradefed initialization, but test_result was created empty
                crashes[job_id] = extract_crash_logs(job_dir)
                continue

            for (
                module_name,
                module_result,
            ) in atest_result.test_runner.AtestTradefedTestRunner.items():
                for tc in module_result.PASSED:
                    details_str = str(tc.details) if tc.details is not None else None
                    all_results.append(
                        ParsedResult(
                            test_name=tc.test_name,
                            status="PASS",
                            test_time=tc.test_time,
                            job_id=job_id,
                            details=details_str,
                        )
                    )
                for tc in module_result.FAILED:
                    details_str = str(tc.details) if tc.details is not None else None
                    all_results.append(
                        ParsedResult(
                            test_name=tc.test_name,
                            status="FAIL",
                            test_time=tc.test_time,
                            job_id=job_id,
                            details=details_str,
                        )
                    )
                for tc in module_result.IGNORED:
                    details_str = str(tc.details) if tc.details is not None else None
                    all_results.append(
                        ParsedResult(
                            test_name=tc.test_name,
                            status="IGNORED",
                            test_time=tc.test_time,
                            job_id=job_id,
                            details=details_str,
                        )
                    )

        except Exception as e:
            logger.error(f"Failed to parse {test_result_file}: {e}")
            crashes[job_id] = f"JSON Parsing Error for test_result: {e}"

    return all_results, crashes
