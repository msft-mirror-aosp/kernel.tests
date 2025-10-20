# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2025, Google
# Author: Maciej Żenczykowski

.PHONY: all du diff start stop status dump hint macs install clean

# Default target: runs all other build targets
all: clatd.o send-udp0.clang send-udp0.gcc send-udp0 clatutil.clang clatutil.g++ clatutil du

CFLAGS=-O2 -Wall -Werror
LIBBPF_CFLAGS = -I/usr/include/bpf -I/usr/include/libbpf
LIBBPF_LIBS = -lbpf

clatd.o: clatd.c clatd.h
	clang-19 -target bpf $(CFLAGS) -I/usr/include/x86_64-linux-gnu -g -c $< -o $@

send-udp0.clang: send-udp0.c
	clang-19 $(CFLAGS) $< -o $@

send-udp0.gcc: send-udp0.c
	gcc $(CFLAGS) $< -o $@

send-udp0: send-udp0.clang
	ln -sf send-udp0.clang send-udp0

clatutil.clang: clatutil.cpp clatd.h BpfMap.h
	clang++-19 $(CFLAGS) -Wno-vla-cxx-extension -Wno-non-c-typedef-for-linkage -ftrivial-auto-var-init=zero $< -o $@

clatutil.g++: clatutil.cpp clatd.h BpfMap.h
	g++ $(CFLAGS) -Wno-template-id-cdtor -Wno-attributes $< -o $@

clatutil: clatutil.clang
	ln -sf clatutil.clang clatutil

# A target to show disk usage
du: clatd.o send-udp0.clang send-udp0.gcc clatutil.clang clatutil.g++
	du -hs $^

diff: clatutil.clang clatutil.g++
	diff -Naur <(sudo ./clatutil.clang) <(sudo ./clatutil.g++) && echo OK

start:
	sudo ./install.sh

stop:
	sudo ./install.sh reset

status:
	sudo ./status.sh

dump: clatutil
	sudo ./clatutil

hint: clatutil
	sudo ./clatutil get $(shell ip -6 route get 2001:4860:3860::8888 | sed -rn 's@^.* dev ([^ ]+) .*@\1@p') 192.0.0.1

macs:
	sed -rn 's@^4 +enp1s0 +@@p' </proc/net/dev_mcast

install: clatd.o clatutil start diff

clean:
	rm -f clatd.o send-udp0.clang send-udp0.gcc send-udp0 clatutil.clang clatutil.g++ clatutil
