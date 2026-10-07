import logging
from pathlib import Path

import click

from matrix_reporter.parser import extract_results, parse_config
from matrix_reporter.renderer import process_and_render

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)


@click.command()
@click.option(
    "--report-dir",
    type=click.Path(exists=True, file_okay=False, dir_okay=True, path_type=Path),
    required=True,
    help="Path to the reports directory (e.g. reports/20260902_132727)",
)
@click.option(
    "--config",
    type=click.Path(exists=True, file_okay=True, dir_okay=False, path_type=Path),
    required=False,
    help="Path to the e2e_matrix.json config file",
)
@click.option(
    "--max-rows",
    type=int,
    default=30,
    help=(
        "Maximum number of test cases to print the full matrix "
        "in terminal before filtering to failures only"
    ),
)
def main(report_dir: Path, config: Path, max_rows: int):
    """Parse ATest JSON logs and generate a test execution matrix report."""
    logger.info(f"Analyzing report directory: {report_dir}")

    job_names = {}
    if config:
        logger.info(f"Parsing configuration: {config}")
        job_names = parse_config(config)

    results, crashes = extract_results(report_dir)

    if not results and not crashes:
        logger.warning("No valid test results or crash logs found in the given directory.")
        return

    process_and_render(results, crashes, job_names, report_dir, max_rows)


if __name__ == "__main__":
    main()
