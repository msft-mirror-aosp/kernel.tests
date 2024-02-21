#!/usr/bin/python3
#
# Copyright 2016 The Android Open Source Project
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

import errno
from socket import *  # pylint: disable=wildcard-import
import unittest

import gzip
import net_test


class RemovedFeatureTest(net_test.NetworkTest):
  KCONFIG = None

  @classmethod
  def loadKernelConfig(cls):
    cls.KCONFIG = {}
    with gzip.open("/proc/config.gz", mode="rt") as f:
      for line in f:
        line = line.strip()
        parts = line.split("=")
        if (len(parts) == 2):
          # Lines of the form:
          # CONFIG_FOO=y
          cls.KCONFIG[parts[0]] = parts[1]

  @classmethod
  def setUpClass(cls):
    cls.loadKernelConfig()

  def assertFeatureEnabled(self, featureName):
    return self.assertEqual("y", self.KCONFIG[featureName])

  def assertFeatureAbsent(self, featureName):
    return self.assertTrue(featureName not in self.KCONFIG)

  def testNetfilterRejectEnabled(self):
    """Verify that CONFIG_IP{,6}_NF_{FILTER,TARGET_REJECT} is enabled."""
    self.assertFeatureEnabled("CONFIG_IP_NF_FILTER")
    self.assertFeatureEnabled("CONFIG_IP_NF_TARGET_REJECT")

    self.assertFeatureEnabled("CONFIG_IP6_NF_FILTER")
    self.assertFeatureEnabled("CONFIG_IP6_NF_TARGET_REJECT")

  def testRemovedAndroidParanoidNetwork(self):
    """Verify that ANDROID_PARANOID_NETWORK is gone.

       On a 4.14-q kernel you can achieve this by simply
       changing the ANDROID_PARANOID_NETWORK default y to n
       in your kernel source code in net/Kconfig:

       @@ -94,3 +94,3 @@ endif # if INET
        config ANDROID_PARANOID_NETWORK
               bool "Only allow certain groups to create sockets"
       -       default y
       +       default n
    """
    AID_NET_RAW = 3004
    with net_test.RunAsUidGid(12345, AID_NET_RAW):
      self.assertRaisesErrno(errno.EPERM, socket, AF_PACKET, SOCK_RAW, 0)


if __name__ == "__main__":
  unittest.main()
