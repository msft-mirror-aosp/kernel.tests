#!/usr/bin/python3
#
# Copyright 2018 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import ctypes
import importlib
import os
import sys
import unittest

import gki
import namespace
import net_test

# man 2 personality
personality = ctypes.CDLL(None).personality
personality.restype = ctypes.c_int
personality.argtypes = [ctypes.c_ulong]

# From Linux kernel's include/uapi/linux/personality.h
PER_QUERY = 0xFFFFFFFF
PER_LINUX = 0
PER_LINUX32 = 8

all_test_modules = [
    'anycast_test',
    'bpf_test',
    'csocket_test',
    'cstruct_test',
    'kernel_feature_test',
    'leak_test',
    'multinetwork_test',
    'neighbour_test',
    'netlink_test',
    'nf_test',
    'parameterization_test',
    'ping6_test',
    'resilient_rs_test',
    'sock_diag_test',
    'srcaddr_selection_test',
    'sysctls_test',
    'tcp_fastopen_test',
    'tcp_nuke_addr_test',
    'tcp_repair_test',
    'xfrm_algorithm_test',
    'xfrm_test',
    'xfrm_tunnel_test',
]


def FilterTests(suite, exclude_test_ids):
  """Returns a new TestSuite, skipping tests that exactly match the exclude_test_ids.

  Args:
    suite: The unittest.TestSuite to filter.
    exclude_test_ids: A list of exact test IDs to exclude.

  Returns:
    A new unittest.TestSuite containing only the non-excluded tests.
  """
  new_suite = unittest.TestSuite()
  for test in suite:
    if isinstance(test, unittest.TestSuite):
      # Recursively filter nested suites
      sub_suite = FilterTests(test, exclude_test_ids)
      if sub_suite.countTestCases() > 0:
        new_suite.addTest(sub_suite)
    elif isinstance(test, unittest.TestCase):
      # Check for exact match
      if test.id() in exclude_test_ids:
        continue
      new_suite.addTest(test)
  return new_suite


def RunTests(modules_to_test, excludes=None):
  uname = os.uname()
  linux = uname.sysname
  kver = uname.release
  arch = uname.machine
  p = personality(PER_LINUX)
  true_arch = os.uname().machine
  personality(p)
  print('Running on %s %s %s %s/%s-%sbit%s%s'
        % (linux, kver, net_test.LINUX_VERSION, true_arch, arch,
           '64' if sys.maxsize > 0x7FFFFFFF else '32',
           ' GKI' if gki.IS_GKI else '', ' GSI' if net_test.IS_GSI else ''),
        file=sys.stderr)
  namespace.EnterNewNetworkNamespace()

  # First, run InjectTests on all modules, to ensure that any parameterized
  # tests in those modules are injected.
  for name in modules_to_test:
    importlib.import_module(name)
    if hasattr(sys.modules[name], 'InjectTests'):
      sys.modules[name].InjectTests()

  test_suite = unittest.defaultTestLoader.loadTestsFromNames(modules_to_test)

  # Filter the tests if exclude patterns are provided
  if excludes:
    test_suite = FilterTests(test_suite, excludes)

  assert test_suite.countTestCases() > 0, (
      'Inconceivable: no tests found or all tests are filtered out! Command'
      ' line: %s'
      % ' '.join(sys.argv)
  )

  runner = unittest.TextTestRunner(verbosity=2)
  result = runner.run(test_suite)
  sys.exit(not result.wasSuccessful())


if __name__ == '__main__':
  # Use argparse to handle the exclude option and positional arguments
  parser = argparse.ArgumentParser(
      description='Run network tests.',
      formatter_class=argparse.ArgumentDefaultsHelpFormatter,
  )

  parser.add_argument(
      '--exclude',
      action='append',
      dest='excludes',
      help=(
          'Do not run tests with the exact specified ID. Can be used multiple'
          ' times.'
      ),
  )

  parser.add_argument(
      'modules',
      nargs='*',
      help=(
          'Specific test modules to run. If not specified, all modules will'
          ' be run'
      ),
  )

  args = parser.parse_args()

  # Determine which modules to run
  modules_to_run = args.modules or all_test_modules

  RunTests(modules_to_run, excludes=args.excludes)
