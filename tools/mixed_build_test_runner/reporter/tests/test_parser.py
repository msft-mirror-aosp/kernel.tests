from matrix_reporter.models import AtestResult, MatrixConfig


def test_models_valid():
    # Simple test for JobConfig and MatrixConfig
    data = {"jobs": [{"job_id": "job_1", "display_name": "Job 1"}, {"job_id": "job_2"}]}
    config = MatrixConfig.model_validate(data)
    assert len(config.jobs) == 2
    assert config.jobs[0].display_name == "Job 1"
    assert config.jobs[1].display_name is None


def test_atest_result_parsing():
    data = {
        "args": "vts_ltp_test_x86_64",
        "test_runner": {
            "AtestTradefedTestRunner": {
                "x86_64 vts_ltp_test_x86_64": {
                    "PASSED": [
                        {
                            "test_name": "syscalls.write01_64bit#syscalls.write01_64bit",
                            "test_time": "(2.527s)",
                            "details": None,
                        }
                    ],
                    "FAILED": [
                        {
                            "test_name": "syscalls.write02_64bit#syscalls.write02_64bit",
                            "test_time": "(244ms)",
                            "details": "Some Error",
                        }
                    ],
                    "IGNORED": [],
                    "summary": {"PASSED": 1, "FAILED": 1, "IGNORED": 0},
                }
            }
        },
    }
    result = AtestResult.model_validate(data)
    assert result.test_runner is not None
    assert result.test_runner.AtestTradefedTestRunner is not None
    module = result.test_runner.AtestTradefedTestRunner["x86_64 vts_ltp_test_x86_64"]
    assert len(module.PASSED) == 1
    assert len(module.FAILED) == 1
    assert module.PASSED[0].test_name == "syscalls.write01_64bit#syscalls.write01_64bit"
