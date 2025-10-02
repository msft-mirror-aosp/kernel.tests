#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2025, Google
# Author: Maciej Żenczykowski

set -e
set -u

get_ipv4_default_route_device() {
  ip -4 route get 8.8.8.8 | sed -rn 's@^.* dev ([^ ]+) .*@\1@p'
}

get_ipv6_default_route_device() {
  ip -6 route get 2001:4860:4860::8888 | sed -rn 's@^.* dev ([^ ]+) .*@\1@p'
}

declare -r DEV4=`get_ipv4_default_route_device || echo unknown`
declare -r DEV6=`get_ipv6_default_route_device`

declare -r DEV="${DEV6}"

echo "--- IPv6 route ---"
ip -6 route get 2001:4860:4860::8888

echo "--- IPv4 route ---"
ip -4 route get 8.8.8.8 || :

echo "--- Detected ipv6/ipv4 default route via ${DEV6}/${DEV4}. ---"

echo "--- IP addr (non deprecated) ---"
ip addr show dev "${DEV6}" -deprecated

echo "--- ip neigh proxy ${DEV6} ---"
ip -6 neigh show proxy dev "${DEV6}"

#echo "--- tc qdisc ${DEV6} ---"
#tc qdisc show dev "${DEV6}"

#echo "--- tc filter ${DEV6} ---"
#tc filter show dev "${DEV6}"

echo "--- tc filter ${DEV6} ingress ---"
tc filter show dev "${DEV6}" ingress

echo "--- tc filter ${DEV6} egress ---"
tc filter show dev "${DEV6}" egress

echo "--- CLAT eBPF maps ---"
sudo bpftool map | egrep ' name clat_(ifmac|srcip|input|timer|output)_map ' || :

echo
for map in ifmac srcip input timer output; do
  echo -n "${map}: "
  sudo bpftool map dump name "clat_${map}_map" | tr '\n' ' ' | sed -r 's@  +@ @g'
  echo
done

echo "--- CLAT eBPF programs ---"
sudo bpftool prog | egrep ' name clat_(e|in)gress ' || :

echo "==="

if [[ "${1:-}" == 'wipe' ]]; then
  sudo tc filter del dev "${DEV6}" ingress
  sudo tc filter del dev "${DEV6}" egress
  sudo ip -6 neigh flush proxy dev "${DEV6}"
  sudo ip -4 addr del 192.0.0.1/32 dev "${DEV4}" || :
  echo OK
fi
