// SPDX-License-Identifier: GPL-2.0
// Copyright (C) 2025, Google
// Author: Maciej Żenczykowski

#pragma once

#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/in6.h>

#include <stdbool.h>
#include <stdint.h>

#ifndef __cplusplus
#define static_assert(cond, msg) _Static_assert(cond, msg)
#endif

// This header file is shared by eBPF kernel programs (C, 64-bit BPF architecture)
// and userspace (which could potentially be 32-bit C++/Java x86/arm/...)
//
// Hence: explicitly pad all relevant structures and assert that their size
// is the sum of the sizes of their fields.
#define STRUCT_SIZE(name, size) static_assert(sizeof(name) == (size), "Incorrect struct size.")

#define BPF_CLAT_ERRORS \
    ERR(UNUSED) \
    ERR(INGRESS_IGN_OTHERHOST) \
    ERR(INGRESS_IGN_MULTICAST) \
    ERR(INGRESS_IGN_BROADCAST) \
    ERR(INGRESS_IGN_LOOPBACK) \
    ERR(INGRESS_IGN_OUTGOING) \
    ERR(INGRESS_IGN_NOT_HOST) \
    ERR(INGRESS_ERR_NOT_IPV6) \
    ERR(INGRESS_IGN_TOO_SHORT) \
    ERR(INGRESS_IGN_WRONG_ETHERTYPE) \
    ERR(INGRESS_IGN_WRONG_IP6VERSION) \
    ERR(INGRESS_IGN_TOO_LONG) \
    ERR(INGRESS_ERR_ICMPV6_1) \
    ERR(INGRESS_ERR_ICMPV6_2) \
    ERR(INGRESS_ERR_ICMPV6_3) \
    ERR(INGRESS_ERR_ICMPV6_4) \
    ERR(INGRESS_CNT_ICMPV6_NS_NA) \
    ERR(INGRESS_IGN_NOT_CLAT) \
    ERR(INGRESS_IGN_FRAG_OOB) \
    ERR(INGRESS_IGN_FRAG_MALFORMED) \
    ERR(INGRESS_ERR_ICMPV6_OOB) \
    ERR(INGRESS_ERR_ICMPV6_UNKNOWN_CODE) \
    ERR(INGRESS_ERR_ICMPV6_UNKNOWN_TYPE) \
    ERR(INGRESS_ERR_UNKNOWN_PROTOCOL) \
    ERR(INGRESS_ERR_CHANGE_PROTO) \
    ERR(INGRESS_ERR_ADJUST_ROOM) \
    ERR(INGRESS_ERR_OOB) \
    ERR(INGRESS_CNT_XLAT_REDIRECT) \
    ERR(INGRESS_CNT_XLAT) \
    ERR(EGRESS_IGN_NOT_IPV4) \
    ERR(EGRESS_ERR_TOO_SHORT) \
    ERR(EGRESS_ERR_WRONG_IP4VERSION) \
    ERR(EGRESS_ERR_IPV4_OPTIONS) \
    ERR(EGRESS_ERR_IPV4_MULTICAST) \
    ERR(EGRESS_ERR_IPV4_BROADCAST) \
    ERR(EGRESS_ERR_IPV4_WRONG_CHECKSUM) \
    ERR(EGRESS_ERR_IPV4_TOO_SHORT) \
    ERR(EGRESS_ERR_NOT_CLAT) \
    ERR(EGRESS_ERR_UDP4_TOO_SHORT) \
    ERR(EGRESS_ERR_UDP4_CSUM0_FRAG) \
    ERR(EGRESS_CNT_UDP4_CSUM0) \
    ERR(EGRESS_ERR_ICMP_OOB) \
    ERR(EGRESS_ERR_ICMP_UNKNOWN) \
    ERR(EGRESS_ERR_UNKNOWN_PROTO) \
    ERR(EGRESS_ERR_CHANGE_PROTO) \
    ERR(EGRESS_ERR_ADJUST_ROOM) \
    ERR(EGRESS_ERR_ETHER_OOB) \
    ERR(EGRESS_ERR_ETHER_FRAG_OOB) \
    ERR(EGRESS_ERR_RAWIP_OOB) \
    ERR(EGRESS_ERR_RAWIP_FRAG_OOB) \
    ERR(EGRESS_CNT_XLAT_REDIRECT) \
    ERR(EGRESS_CNT_XLAT) \
    ERR(_MAX)

#ifdef __cplusplus
#define ERR(x) #x,
static const char *bpf_clat_errors[] = {
    BPF_CLAT_ERRORS
};
#undef ERR
#endif

#define ERR(x) BPF_CLAT_ERR_ ##x,
typedef enum {
    BPF_CLAT_ERRORS
    JUST_MAKE_IT_32_BIT = 0xFFFFFFFF,
} ClatErrorKey;
#undef ERR
STRUCT_SIZE(ClatErrorKey, 4);

#define TC_COUNT3(cnttype, dirlong, counter, dirshort) do { \
    uint32_t code = BPF_CLAT_ERR_ ## dirlong ## _ ## cnttype ## _ ## counter; \
    uint64_t *count = bpf_clat_err ## dirshort ## _map_lookup_elem(&code); \
    if (count) __sync_fetch_and_add(count, 1); \
} while(0)

#define TC_COUNT2(cnttype, dirlong, counter, dirshort) TC_COUNT3(cnttype, dirlong, counter, dirshort)

// Before using these, DIRLONG and DIRSHORT should be #defined to INGRESS/EGRESS and in/out
#define TC_COUNT(counter)     TC_COUNT2(CNT, DIRLONG, counter, DIRSHORT)
#define TC_PUNT(counter) do { TC_COUNT2(IGN, DIRLONG, counter, DIRSHORT); return TC_ACT_PIPE; } while(0)
#define TC_DROP(counter) do { TC_COUNT2(ERR, DIRLONG, counter, DIRSHORT); return TC_ACT_SHOT; } while(0)

typedef struct {
    uint32_t ifindex;

#ifdef __cplusplus
    static const char* name() { return "IfIndex"; }
    std::string toString() const { return ifindex_to_string(ifindex); }
#endif
} IfIndex;
STRUCT_SIZE(IfIndex, 4);  // 4

typedef struct {
    __u8 mac8[ETH_ALEN];

#ifdef __cplusplus
    static const char* name() { return "MacAddress"; }
    std::string toString() const {
        char buf[6*3];
        snprintf(buf, sizeof(buf), "%02x:%02x:%02x:%02x:%02x:%02x",
                 mac8[0], mac8[1], mac8[2], mac8[3], mac8[4], mac8[5]);
        return buf;
    }
#endif
} MacAddress;
STRUCT_SIZE(MacAddress, 6);  // 6

typedef struct {
    uint32_t ifindex;
    struct in6_addr local6;

#ifdef __cplusplus
    static const char* name() { return "ClatSrcIpKey"; }
    std::string toString() const {
        return "{ifindex: " + ifindex_to_string(ifindex) + ", local6: " + ip6_to_string(local6) + "}";
    }
#endif
} ClatSrcIpKey;
STRUCT_SIZE(ClatSrcIpKey, 4 + 16);  // 20

typedef struct {
    struct in6_addr pfx96;
    struct in_addr local4;

#ifdef __cplusplus
    static const char* name() { return "ClatSrcIpValue"; }
    std::string toString() const {
        return "{pfx96: " + ip6_to_string(pfx96) + "/96, local4: " + ip4_to_string(local4) + "}";
    }
#endif
} ClatSrcIpValue;
STRUCT_SIZE(ClatSrcIpValue, 16 + 4);  // 20

typedef struct {
    uint32_t iif;            // The input interface index
    struct in6_addr pfx96;   // The source /96 nat64 prefix, bottom 32 bits must be 0
    struct in6_addr local6;  // The full 128-bits of the destination IPv6 address

#ifdef __cplusplus
    static const char* name() { return "ClatIngress6Key"; }
    std::string toString() const {
        return "{iif: " + ifindex_to_string(iif) + ", pfx96: " + ip6_to_string(pfx96) + "/96, local6: " + ip6_to_string(local6) + "}";
    }
#endif
} ClatIngress6Key;
STRUCT_SIZE(ClatIngress6Key, 4 + 2 * 16);  // 36

typedef struct {
    uint32_t oif;           // The output interface to redirect to (0 means don't redirect)
    struct in_addr local4;  // The destination IPv4 address
    uint64_t packets;       // Count of translated gso (large) packets
    uint64_t bytes;         // Sum of post-translation skb->len

#ifdef __cplusplus
    static const char* name() { return "ClatIngress6Value"; }
    std::string toString() const {
        return "{oif: " + ifindex_to_string(oif) +
               ", local4: " + ip4_to_string(local4) +
               ", packets: " + std::to_string(packets) +
               ", bytes:" + std::to_string(bytes) + "}";
    }
#endif
} ClatIngress6Value;
STRUCT_SIZE(ClatIngress6Value, 4 + 4 + 8 + 8);  // 24

typedef struct {
    uint32_t iif;           // The input interface index
    struct in_addr local4;  // The source IPv4 address

#ifdef __cplusplus
    static const char* name() { return "ClatEgress4Key"; }
    std::string toString() const {
        return "{iif: " + ifindex_to_string(iif) + ", local4: " + ip4_to_string(local4) + "}";
    }
#endif
} ClatEgress4Key;
STRUCT_SIZE(ClatEgress4Key, 4 + 4);  // 8

typedef struct {
    uint32_t oif;            // The output interface to redirect to
    struct in6_addr local6;  // The full 128-bits of the source IPv6 address
    struct in6_addr pfx96;   // The destination /96 nat64 prefix, bottom 32 bits must be 0
    bool oifIsEthernet;      // Whether the output interface requires ethernet header
    uint8_t pad;
    uint16_t pmtu;
    uint64_t packets;        // Count of translated gso (large) packets
    uint64_t bytes;          // Sum of post-translation skb->len

#ifdef __cplusplus
    static const char* name() { return "ClatEgress4Value"; }
    std::string toString() const {
        std::string padStr = pad ? ", pad: " + std::to_string(pad) + "!" : "";
        return "{oif: " + ifindex_to_string(oif) +
               ", local6: " + ip6_to_string(local6) +
               ", pfx96: " + ip6_to_string(pfx96) + "/96" +
               ", oifIsEthernet: " + (oifIsEthernet ? "true" : "false") +
               padStr +
               ", pmtu: " + std::to_string(pmtu) +
               ", packets: " + std::to_string(packets) +
               ", bytes:" + std::to_string(bytes) + "}";
    }
#endif
} ClatEgress4Value;
STRUCT_SIZE(ClatEgress4Value, 4 + 2 * 16 + 1 + 1 + 2 + 8 + 8);  // 56

typedef struct {
    __u32 count;
    __u32 pad;
    __u64 last_time;

#ifdef __cplusplus
    static const char* name() { return "ClatTimerValue"; }
    std::string toString() const {
        std::string padStr = pad ? ", pad: " + std::to_string(pad) + "!" : "";
        return "{count: " + std::to_string(count) + padStr + ", last_time: " + std::to_string(last_time) + "}";
    }
#endif
} ClatTimerValue;
STRUCT_SIZE(ClatTimerValue, 4 + 4 + 8);  // 16

#undef STRUCT_SIZE
