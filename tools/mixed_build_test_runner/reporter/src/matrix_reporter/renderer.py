import re
from pathlib import Path
from typing import Any, Dict, List, Optional

import pandas as pd
from colorama import Fore, Style
from jinja2 import Environment, FileSystemLoader, select_autoescape
from tabulate import tabulate

from matrix_reporter.models import JobConfig, ParsedResult


def parse_time_ms(time_str: str) -> int:
    """Parse time string like '(2.727s)' or '(339ms)' to milliseconds."""
    if not time_str:
        return 0
    # Extract numbers and unit
    match = re.search(r"([\d\.]+)(s|ms)", time_str)
    if not match:
        return 0
    val = float(match.group(1))
    unit = match.group(2)
    if unit == "s":
        return int(val * 1000)
    return int(val)


def render_terminal(df: pd.DataFrame, summary_df: pd.DataFrame, max_rows: int):
    """Render the matrix to terminal using tabulate."""
    if df.empty:
        print("No test results found.")
        return

    print("\n" + "=" * 50)
    print("Test Execution Summary:")
    print(tabulate(summary_df, headers="keys", tablefmt="grid", showindex=False))  # type: ignore[arg-type]
    print("=" * 50 + "\n")

    failed_only = df[df.isin(["FAIL"]).any(axis=1)]

    if len(df) <= max_rows:
        print("Detailed Test Matrix:")
        matrix_to_print = df
    else:
        print(f"Total test cases ({len(df)}) > {max_rows}. Showing ONLY failed test cases:")
        matrix_to_print = failed_only

    if matrix_to_print.empty:
        print("No failures to display! 🎉")
        return

    def colorize(val):
        if val == "PASS":
            return f"{Fore.GREEN}{val}{Style.RESET_ALL}"
        elif val == "FAIL":
            return f"{Fore.RED}{val}{Style.RESET_ALL}"
        elif val == "IGNORED":
            return f"{Fore.YELLOW}{val}{Style.RESET_ALL}"
        elif val == "NOT_EXECUTED":
            return f"{Style.DIM}{val}{Style.RESET_ALL}"
        return val

    colored_df = matrix_to_print.map(colorize)
    print(tabulate(colored_df, headers="keys", tablefmt="grid", showindex=True))  # type: ignore[arg-type]


def render_html(
    df: pd.DataFrame,
    summary_data: List[Dict[str, Any]],
    report_dir: Path,
    job_configs: Dict[str, JobConfig],
    error_details: Dict[str, Dict[str, str]],
    slowest_tests: List[Dict[str, Any]],
    crashes: Dict[str, str],
    retried_tests: Optional[Dict[str, Dict[str, List[str]]]] = None,
):
    """Render the matrix to HTML using Jinja2."""
    template_dir = Path(__file__).parent.parent.parent / "templates"
    env = Environment(
        loader=FileSystemLoader(template_dir), autoescape=select_autoescape(["html", "xml"])
    )

    try:
        template = env.get_template("matrix_report.html.j2")
    except Exception as e:
        print(f"Failed to load template: {e}")
        return

    name_to_job = {}
    for job_id, conf in job_configs.items():
        disp = conf.display_name if conf.display_name else job_id
        name_to_job[disp] = job_id

    def get_job_id(col_name):
        return name_to_job.get(col_name, col_name)

    html_out = template.render(
        columns=df.columns.tolist() if not df.empty else [],
        index=df.index.tolist() if not df.empty else [],
        data=df.values.tolist() if not df.empty else [],
        summary_data=summary_data,
        get_job_id=get_job_id,
        total_tests=len(df),
        job_configs=list(job_configs.values()),
        error_details=error_details,
        slowest_tests=slowest_tests,
        crashes=crashes,
        retried_tests=retried_tests or {},
    )

    out_file = report_dir / "matrix_report.html"
    out_file.write_text(html_out, encoding="utf-8")
    print(f"HTML report generated at: {out_file}")


def render_csv(df: pd.DataFrame, report_dir: Path):
    """Render the matrix to CSV."""
    if df.empty:
        return
    out_file = report_dir / "matrix_report.csv"
    df.to_csv(out_file, index=True, index_label="Test Case")
    print(f"CSV report generated at: {out_file}")


def render_markdown(df: pd.DataFrame, report_dir: Path):
    """Render the matrix to Markdown table."""
    if df.empty:
        return
    out_file = report_dir / "matrix_report.md"
    df_md = df.copy()
    df_md.index.name = "Test Case"
    out_file.write_text(f"{df_md.to_markdown(index=True)}\n", encoding="utf-8")
    print(f"Markdown report generated at: {out_file}")


def process_and_render(
    results: List[ParsedResult],
    crashes: Dict[str, str],
    job_configs: Dict[str, JobConfig],
    report_dir: Path,
    max_rows: int = 30,
):
    if not results and not crashes:
        print("No results to render.")
        return

    job_names = {
        job_id: (conf.display_name if conf.display_name else job_id)
        for job_id, conf in job_configs.items()
    }

    mapped_crashes = {}
    for job_id, log in crashes.items():
        mapped_crashes[job_names.get(job_id, job_id)] = log

    # Extract slowest tests
    for r in results:
        r.__dict__["time_ms"] = parse_time_ms(r.test_time) if r.test_time else 0

    sorted_by_time = sorted(
        [r for r in results if r.__dict__.get("time_ms", 0) > 0],
        key=lambda x: x.__dict__["time_ms"],
        reverse=True,
    )

    slowest_tests = []
    for r in sorted_by_time[:10]:
        disp = job_names.get(r.job_id, r.job_id)
        slowest_tests.append({"test_name": r.test_name, "environment": disp, "time": r.test_time})

    # Extract error details
    error_details: Dict[str, Dict[str, str]] = {}
    for r in results:
        if r.status == "FAIL" or (
            r.details and str(r.details).strip() and str(r.details) != "None"
        ):
            disp = job_names.get(r.job_id, r.job_id)
            if disp not in error_details:
                error_details[disp] = {}
            error_details[disp][r.test_name] = str(r.details)

    retried_tests: Dict[str, Dict[str, List[str]]] = {}
    if results:
        # Convert to DataFrame
        raw_df = pd.DataFrame([r.model_dump() for r in results])

        # Extract duplicates
        dups = raw_df[raw_df.duplicated(subset=["job_id", "test_name"], keep=False)]
        if not dups.empty:
            for job_id_val, group in dups.groupby("job_id"):
                job_id = str(job_id_val)
                disp = job_names.get(job_id, job_id)
                retried_tests[disp] = {}
                for test_name_val, sub_group in group.groupby("test_name"):
                    test_name = str(test_name_val)
                    retried_tests[disp][test_name] = [str(s) for s in sub_group["status"].tolist()]

        def prioritize_status(series):
            vals = set(series)
            if "FAIL" in vals:
                return "FAIL"
            if "PASS" in vals:
                return "PASS"
            if "IGNORED" in vals:
                return "IGNORED"
            return list(vals)[0]

        # Pivot safely using pivot_table to handle duplicates
        pivot_df = raw_df.pivot_table(
            index="test_name", columns="job_id", values="status", aggfunc=prioritize_status
        )
        pivot_df = pivot_df.fillna("NOT_EXECUTED")
        pivot_df.rename(columns=job_names, inplace=True)

        new_index = []
        for idx in pivot_df.index:
            parts = str(idx).split("#")
            if len(parts) == 2 and parts[0] == parts[1]:
                new_index.append(parts[0])
            else:
                new_index.append(idx)
        pivot_df.index = new_index
        pivot_df.index.name = "Test Case"

        def sorting_key(row):
            if "FAIL" in row.values:
                return 0
            elif "NOT_EXECUTED" in row.values:
                return 2
            else:
                return 1

        sort_keys = pivot_df.apply(sorting_key, axis=1)
        pivot_df["_sort_key"] = sort_keys
        pivot_df = pivot_df.sort_values(
            by=[
                "_sort_key",
                str(pivot_df.columns[0])
                if not pivot_df.columns.empty
                else str(pivot_df.index.name),
            ]
        )
        pivot_df.drop(columns=["_sort_key"], inplace=True)
    else:
        pivot_df = pd.DataFrame()

    summary_data = []
    if not pivot_df.empty:
        for col in pivot_df.columns:
            counts = pivot_df[col].value_counts()
            summary_data.append(
                {
                    "Environment": col,
                    "PASS": counts.get("PASS", 0),
                    "FAIL": counts.get("FAIL", 0),
                    "IGNORED": counts.get("IGNORED", 0),
                    "NOT_EXECUTED": counts.get("NOT_EXECUTED", 0),
                    "TOTAL": len(pivot_df),
                }
            )
    summary_df = pd.DataFrame(summary_data)

    render_terminal(pivot_df, summary_df, max_rows)
    render_csv(pivot_df, report_dir)
    render_markdown(pivot_df, report_dir)
    render_html(
        pivot_df,
        summary_data,
        report_dir,
        job_configs,
        error_details,
        slowest_tests,
        mapped_crashes,
        retried_tests,
    )
