#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2025, Google
# Author: Maciej Żenczykowski

# Dev script to auto-detect and install clat program/maps for ipv6-only nat64/dns64 network.
# Requires 5.10+ Linux Kernel
#
# Depends on (at least):
#   bpftool, iproute2 (ip, tc), ndisc6
#   bash, coreutils (chmod, cut, printf, sort, tr), host, sed
#
# bash likely needs to be relatively new and full featured
# host can be found in bind-utils or bind9-host or something like that
#
# Kernel must include at *least* the following modules:
#   act_bpf       -- bpf action [currently commented out]
#   act_gact      -- generic actions (drop)
#   cls_bpf       -- bpf classifier [currently in use]
#   cls_matchall  -- matchall classifier
#   cls_u32       -- u32 classifier
#
# Upstream (unresolved) Linux kernel thread:
#   https://lore.kernel.org/netdev/20221214232059.760233-1-decot+git@google.com/T/

set -e
set -u

# Change into the directory containing this script
cd "${0%/*}"

# Dns fetch of 96-bit prefix
pfx96() {
  host -t AAAA ipv4only.arpa | sed -rn 's@^ipv4only[.]arpa has IPv6 address ([0-9a-f:]+)::c000:a[ab]@\1::@p' | sort -u
}

# IPv6 route lookup to a destination address, argument 1/2/3 to return GATEWAY, DEVICE, SRCIP
gt() {
  ip -6 route get "$1" | sed -rn 's@^.* via ([0-9a-f:]+) dev ([a-z0-9]+) .* src ([0-9a-f:]+) .*$@\'$2'@p'
}

# Figure out the requisite configuration
declare -r PFX96=$(pfx96)
declare -r GW=$(gt "${PFX96}" 1)
declare -r DEV=$(gt "${PFX96}" 2)
declare -r SRC=$(gt "${PFX96}" 3)
declare -r IFINDEX=$(< "/sys/class/net/${DEV}/ifindex")
declare -r MTU6=$(< "/proc/sys/net/ipv6/conf/${DEV}/mtu")
declare -r MTU4=$[MTU6-28]  # ipv6 header size - ipv4 header size = 20,  plus an extra 8 bytes for IPv6 Fragmentation Extension Header
declare -r MAC=$(< "/sys/class/net/${DEV}/address")
declare -r LOCAL4=192.0.0.1
declare -r PROXY=$(ip -6 neigh show proxy dev "${DEV}" | cut -d' ' -f1)  # currently configured proxies, if any
declare -r HINT="$(sudo ./clatutil get enp1s0 192.0.0.1)"
echo "PFX96[${PFX96}] GW[${GW}] DEV[${DEV}] IFINDEX[${IFINDEX}] SRC[${SRC}] MTU6[${MTU6}] MTU4[${MTU4}] MAC[${MAC}] LOCAL4[${LOCAL4}] PROXY[${PROXY}] HINT[${HINT}]"

# kernel constant, ip prints 'kernel_ra' but fails to parse it...
declare -r IFAPROT_KERNEL_RA=2

# Seems to work in practice, informational
echo -n "MAIN ADDR on ${DEV} is "
ip addr show dev enp1s0 scope global -deprecated mngtmpaddr proto "${IFAPROT_KERNEL_RA}" | sed -rn 's@^    inet6 ([0-9a-f:]+)/64 .*@\1@p' | head -n 1

# Calculate checksum neutral IPv6 CLAT source address.  Hint will be reused if valid.
declare -r CLATIP="$(./clatutil generate "${SRC}" "${PFX96}" "${LOCAL4}" "${HINT}")"

if [[ "${CLATIP}" == "${HINT}" ]]; then
  declare -r PREEXIST=true
else
  declare -r PREEXIST=false
fi

echo "CLATIP[${CLATIP}] PREEXIST[${PREEXIST}]"

if [[ $(id -u) != 0 ]]; then
  echo "Aborting, not root."
  exit 0
fi

ip -6 neigh flush proxy dev "${DEV}"
ip -4 route del default metric 1 2>/dev/null || :
tc qdisc del dev "${DEV}" clsact 2>/dev/null || :

if [[ "$*" == reset ]]; then
  ip -4 addr del "${LOCAL4}/32" dev "${DEV}" 2>/dev/null || :
  echo 0 > "/proc/sys/net/ipv6/conf/${DEV}/proxy_ndp"
  exit 0
fi

sleep 1

echo 1 > "/proc/sys/net/ipv6/conf/${DEV}/proxy_ndp"

tc qdisc add dev "${DEV}" clsact

#tc filter add dev "${DEV}" ingress prio 1 protocol ipv6 u32 match ip6 src 64:ff9b::/96 match ip6 dst "${CLATIP}" action bpf object-file clatd.o section schedcls/clat_ingress
tc filter add dev "${DEV}" ingress prio 1 protocol ipv6 bpf object-file clatd.o section schedcls/clat_ingress direct-action
tc filter add dev "${DEV}"  egress prio 1 protocol arp  matchall action drop
tc filter add dev "${DEV}"  egress prio 2 protocol ip   bpf object-file clatd.o section schedcls/clat_egress  direct-action
#tc filter add dev "${DEV}"  egress prio 2 protocol ip   u32 match ip  src 192.0.0.1                              action bpf object-file clatd.o section schedcls/clat_egress

ip -4 addr replace "${LOCAL4}/32" dev "${DEV}"

./clatutil install "${IFINDEX}" "${DEV}" "${MAC}" "${MTU4}" "${CLATIP}" "${PFX96}" "${LOCAL4}"

ip -4 route add default via inet6 "${GW}" dev "${DEV}" mtu "${MTU4}" src "${LOCAL4}" metric 1

if ! "${PREEXIST}"; then
  echo "Triggering DAD for ${CLATIP}/128 on ${DEV}"
  sleep 1
  ip -6 addr add "${CLATIP}/128" dev "${DEV}"
  sleep 2
  # it may be enough to get the bpf program to also handle multicast packets
  # do we need the router flag set on our NAs?
  ndisc6 -1 -s "${CLATIP}" "${GW}" "${DEV}"
  ip -6 addr del "${CLATIP}/128" dev "${DEV}"
fi

ip -6 neigh add proxy "${CLATIP}" dev "${DEV}"

ping -c 3 8.8.8.8
