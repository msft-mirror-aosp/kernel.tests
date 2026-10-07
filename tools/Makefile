# Entry point for the shell tests that cover the scripts in this directory.
#
#   make test        run every suite under tests/
#   make test-fast   same, but skip the cases that wait for real timeouts
#   make test-one T=device_util
#                    run only suites whose filename contains 'device_util'
#
# mixed_build_test_runner/ has its own Makefile for its shell suites and the
# Python reporter; 'make test-matrix' delegates to it.

.PHONY: test test-sh test-fast test-one test-matrix test-all

TESTS = tests/run_all.sh

test: test-sh

test-sh:
	@$(TESTS)

test-fast:
	@SKIP_SLOW=1 $(TESTS)

test-one:
	@$(TESTS) $(T)

test-matrix:
	@$(MAKE) -C mixed_build_test_runner test-sh

test-all: test-sh test-matrix
