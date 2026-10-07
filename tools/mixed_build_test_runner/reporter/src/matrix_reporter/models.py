from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class JobConfig(BaseModel):
    job_id: str
    display_name: Optional[str] = None
    builds: Optional[Dict[str, Any]] = None
    model_config = {"extra": "allow"}


class MatrixConfig(BaseModel):
    jobs: List[JobConfig]
    model_config = {"extra": "allow"}


class TestCaseResult(BaseModel):
    test_name: str
    test_time: Optional[str] = None
    details: Optional[Any] = None


class TestModuleResult(BaseModel):
    PASSED: List[TestCaseResult] = Field(default_factory=list)
    FAILED: List[TestCaseResult] = Field(default_factory=list)
    IGNORED: List[TestCaseResult] = Field(default_factory=list)


class TestRunnerOutput(BaseModel):
    AtestTradefedTestRunner: Optional[Dict[str, TestModuleResult]] = None
    model_config = {"extra": "allow"}


class AtestResult(BaseModel):
    test_runner: Optional[TestRunnerOutput] = None
    model_config = {"extra": "allow"}


class ParsedResult(BaseModel):
    test_name: str
    status: str
    test_time: Optional[str] = None
    job_id: str
    details: Optional[str] = None
