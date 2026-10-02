.PHONY: setup clean format lint typecheck test test-py test-sh test-fast test-one build

VENV = reporter/venv
PYTHON = $(VENV)/bin/python
PIP = $(VENV)/bin/pip

setup:
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	cd reporter && ../$(PIP) install -e .[dev]

clean:
	rm -rf $(VENV)
	rm -rf reporter/build reporter/dist reporter/src/*.egg-info reporter/*.egg-info
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -type d -name ".pytest_cache" -exec rm -rf {} +
	find . -type d -name ".mypy_cache" -exec rm -rf {} +
	find . -type d -name ".ruff_cache" -exec rm -rf {} +

format:
	$(PYTHON) -m ruff format reporter/src/ reporter/tests/

lint:
	$(PYTHON) -m ruff check reporter/src/ reporter/tests/

typecheck:
	$(PYTHON) -m mypy reporter/src/ reporter/tests/

# 'test' covers both languages. The shell suites need no venv.
test: test-py test-sh

test-py:
	$(PYTHON) -m pytest reporter/tests/

test-sh:
	@tests/run_all.sh

# Skips the cases that wait for real timeouts to fire.
test-fast:
	@SKIP_SLOW=1 tests/run_all.sh

# Runs only the shell suites whose filename contains $(T), e.g.
#   make test-one T=cleanup
test-one:
	@tests/run_all.sh $(T)

build:
	cd reporter && ../$(PYTHON) -m build
