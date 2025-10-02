// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2025, Google
// Author: Maciej Żenczykowski

#include <arpa/inet.h>
#include <net/if.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cstdarg>
#include <cstdbool>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <memory>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>

#include "BpfMap.h"

static inline std::string ip4_to_string(const struct in_addr& addr) {
    char buf[INET_ADDRSTRLEN];
    return inet_ntop(AF_INET, &addr, buf, sizeof(buf));
}

static inline std::string ip6_to_string(const struct in6_addr& addr) {
    char buf[INET6_ADDRSTRLEN];
    return inet_ntop(AF_INET6, &addr, buf, sizeof(buf));
}

static inline std::string ifindex_to_string(uint32_t ifindex) {
    if (ifindex == 0) return "0";
    char ifname[IF_NAMESIZE];
    const char* name = if_indextoname(ifindex, ifname);
    if (name == NULL) name = "?";
    return std::to_string(ifindex) + " (" + name + ")";
}

#include "clatd.h"

template<typename T> const char* StructName() { return T::name(); }
template<> const char* StructName<uint32_t>() { return "u32"; }
template<> const char* StructName<uint64_t>() { return "u64"; }
template<> const char* StructName<ClatErrorKey>() { return "ClatErrorKey"; }

template<typename T> std::string toString(const T& key) { return key.toString(); }
template<> std::string toString<uint32_t>(const uint32_t& key) { return std::to_string(key); }
template<> std::string toString<uint64_t>(const uint64_t& key) { return std::to_string(key); }
template<> std::string toString<ClatErrorKey>(const ClatErrorKey& key) { return bpf_clat_errors[key]; }

template<typename K, typename V>
void Dump(const char* name, const BpfMap<K, V>& map, bool skipIfZero = false) {
    printf("%s<%s,%s>:\n", name, StructName<K>(), StructName<V>());
    if (!map.isValid()) {
        printf("  Map is not valid.\n\n");
        return;
    }
    map.forAll([&](const K& key, const V& value) {
        if constexpr (std::is_integral_v<V>) if (skipIfZero && !value) return;

        printf("  %s -> %s\n", toString(key).c_str(), toString(value).c_str());
    });
    printf("\n");
}

void char_star_freer(char * const * p) {
    free(*p);
}

// poor man's scopeguard
#define defer(f) __attribute__((cleanup(f)))

int generate(const int argc, const char * const argv[]) {
    if (argc < 5 or argc > 6) {
        fprintf(stderr, "Usage: %s generate <source_ipv6_address> <prefix_ipv6_address> <source_ipv4_address> [<potential_ipv6_addr>]\n", argv[0]);
        return 1;
    }

    const char * const src_ipv6_str = argv[2];
    struct in6_addr src6_addr;

    if (inet_pton(AF_INET6, src_ipv6_str, &src6_addr) != 1) {
        fprintf(stderr, "Error: Invalid source IPv6 address: %s\n", src_ipv6_str);
        return 1;
    }

    defer(char_star_freer)
    char * const pfx_ipv6_str = strdup(argv[3]);

    { // Handle CIDR /96 notation
        const int n = strlen(pfx_ipv6_str) - 3;
        if (n >= 0 && !strcmp(pfx_ipv6_str + n, "/96")) pfx_ipv6_str[n] = 0;
    }

    struct in6_addr pfx_addr;

    if (inet_pton(AF_INET6, pfx_ipv6_str, &pfx_addr) != 1) {
        fprintf(stderr, "Error: Invalid prefix IPv6 address: %s\n", pfx_ipv6_str);
        return 2;
    }

    if (pfx_addr.s6_addr32[3]) {
        fprintf(stderr, "Error: Non zero bottom 32-bits of prefix IPv6 address: %s\n", pfx_ipv6_str);
        return 4;
    }

    const char * const src_ipv4_str = argv[4];
    struct in_addr src4_addr;

    if (inet_pton(AF_INET, src_ipv4_str, &src4_addr) != 1) {
        fprintf(stderr, "Error: Invalid source IPv4 address: %s\n", src_ipv4_str);
        return 5;
    }

    if (!src4_addr.s_addr) {
        fprintf(stderr, "Error: Invalid zero source IPv4 address: %s\n", src_ipv4_str);
        return 6;
    }

    const char * const guess6_addr_str = argv[5];  // maybe NULL
    struct in6_addr guess6_addr = {};
    bool guessed = guess6_addr_str && *guess6_addr_str;

    if (guessed && inet_pton(AF_INET6, guess6_addr_str, &guess6_addr) != 1) {
        fprintf(stderr, "Error: Invalid guessed IPv6 address: %s\n", guess6_addr_str);
        return 7;
    }

  regenerate:
    struct in6_addr clat_addr;

    if (guessed &&
        (src6_addr.s6_addr32[0] == guess6_addr.s6_addr32[0]) &&
        (src6_addr.s6_addr32[1] == guess6_addr.s6_addr32[1])) {
        //fprintf(stderr, "!match '%s'\n", guess6_addr_str);
        clat_addr = guess6_addr;
    } else {
        guessed = false;  // not provided, or wrong /64 subnet mismatch
        //fprintf(stderr, "!no match '%s'\n", guess6_addr_str ?: "<null>");
        std::srand(std::time(nullptr));
        clat_addr = src6_addr;
        clat_addr.s6_addr16[4] = std::rand();
        clat_addr.s6_addr16[5] = std::rand();
        clat_addr.s6_addr16[6] = std::rand();
        clat_addr.s6_addr16[7] = 0;

        uint32_t s = 2 * 0xFFFF - (src4_addr.s_addr & 0xFFFF) - (src4_addr.s_addr >> 16);
        for (int i = 0; i < 8; ++i) s += clat_addr.s6_addr16[i] + pfx_addr.s6_addr16[i];

        clat_addr.s6_addr16[7] = 0xFFFF - (s % 0xFFFF);
    }

    uint32_t sum6 = 0;  // csum of ipv6 src/dst (derived from 0.0.0.0)
    for (int i = 0; i < 8; ++i) sum6 += clat_addr.s6_addr16[i];
    for (int i = 0; i < 8; ++i) sum6 += pfx_addr.s6_addr16[i];
    // in practice sum6 is non-zero, since at least 1-bit will be set...
    sum6 = (sum6 >> 16) + (sum6 & 0xFFFF);  // sum6 in [1,1FFFE]
    sum6 = (sum6 >> 16) + (sum6 & 0xFFFF);  // sum6 in [1,FFFF]

    uint32_t sum4 = src4_addr.s_addr;  // csum of ipv4 src/dst (but dst is 0.0.0.0)
    // in practice sum4 is non-zero, since 0.0.0.0 isn't a valid src4_addr
    sum4 = (sum4 >> 16) + (sum4 & 0xFFFF);  // sum4 in [1,1FFFE]
    sum4 = (sum4 >> 16) + (sum4 & 0xFFFF);  // sum4 in [1,FFFF]

    if (guessed && sum4 != sum6) {
        // guessed address in right /64 subnet, but checksum mismatches --> regenerate it
        guessed = false;
        goto regenerate;
    }

    char clat_ipv6_str[INET6_ADDRSTRLEN];
    if (inet_ntop(AF_INET6, &clat_addr, clat_ipv6_str, INET6_ADDRSTRLEN) == nullptr) {
        fprintf(stderr, "Error converting clat IPv6 address to string.\n");
        return 7;
    }

    if (sum4 != sum6) {
        fprintf(stderr, "Checksum generation failure (%s -> %04X!=%04X).\n", clat_ipv6_str, sum6, sum4);
        return 8;
    }

    printf("%s\n", clat_ipv6_str);
    return 0;
}

int main(const int argc, const char * const argv[]) {
    if (argc > 1 && !strcmp(argv[1], "generate")) return generate(argc, argv);

    BpfMap<ClatErrorKey, uint64_t> clat_errin_map;
    BpfMap<ClatErrorKey, uint64_t> clat_errout_map;
    BpfMap<IfIndex, MacAddress> clat_ifmac_map;
    BpfMap<ClatSrcIpKey, ClatSrcIpValue> clat_srcip_map;
    BpfMap<ClatIngress6Key, ClatIngress6Value> clat_input_map;
    BpfMap<uint32_t, ClatTimerValue> clat_timer_map;
    BpfMap<ClatEgress4Key, ClatEgress4Value> clat_output_map;

    //int count = 0;
    //printf("maps:");
    for (uint32_t map_id = 0; (map_id = bpfGetNextMapId(map_id)) != 0; ) {
        unique_fd fd(bpfGetFdMapById(map_id));
        //if (!fd.ok() && errno == ENOENT) continue;
        if (!fd.ok()) {
            printf(" %d[%d]", map_id, errno);
            continue;
        }
        auto name = bpfGetFdMapName(fd);
        if (!name.ok()) {
            printf(" %d[?%d]", map_id, errno);
            continue;
        }
        if (!fd.ok()) printf("!");

#define CHECK(s) if (name.value() == #s) { if (0) printf(#s ": %u\n", map_id); s.reset(dup_cloexec(fd.get())); }
        CHECK(clat_errin_map);
        CHECK(clat_errout_map);
        CHECK(clat_ifmac_map);
        CHECK(clat_srcip_map);
        CHECK(clat_input_map);
        CHECK(clat_timer_map);
        CHECK(clat_output_map);
#undef CHECK
        //printf(" %d'%s'", map_id, name.value().c_str());
        //++count;
    }
    //printf(" [total:%d]\n", count);

#define CHECK(s) if (!s.isValid()) fprintf(stderr, "Failed to find " #s "\n");
    CHECK(clat_errin_map);
    CHECK(clat_errout_map);
    CHECK(clat_ifmac_map);
    CHECK(clat_srcip_map);
    CHECK(clat_input_map);
    CHECK(clat_timer_map);
    CHECK(clat_output_map);
#undef CHECK

    if (argc > 1 && !strcmp(argv[1], "install")) {
        if (argc != 9) {
            fprintf(stderr, "Usage: %s install <IFINDEX> <IFNAME> <MAC> <MTU4> <SRC_IP6> <PFX96_IP6> <LOCAL_IP4>\n", argv[0]);
            return 1;
        }
        const char* const ifindex_str = argv[2];
        const char* const dev = argv[3];
        const char* const mac_str = argv[4];
        const char* const mtu4_str = argv[5];
        const char* const src_ip6_str = argv[6];
        const char* const pfx96_str = argv[7];
        const char* const local_ip4_str = argv[8];

        const unsigned ifindex = atoi(ifindex_str); //if_nametoindex(dev);
        if (!ifindex) {
            perror("atoi/if_nametoindex failed");
            return 2;
        }

        MacAddress mac;
        int r = sscanf(mac_str, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
                       &mac.mac8[0], &mac.mac8[1], &mac.mac8[2],
                       &mac.mac8[3], &mac.mac8[4], &mac.mac8[5]);
        if (r != 6) {
            fprintf(stderr, "Failed to parse MAC address '%s'\n", mac_str);
            return 3;
        }

        // Parse IP addresses
        struct in_addr local4;
        if (inet_pton(AF_INET, local_ip4_str, &local4) != 1) {
            fprintf(stderr, "Failed to parse IPv4 address: %s\n", local_ip4_str);
            return 4;
        }

        struct in6_addr src6, pfx96;
        if (inet_pton(AF_INET6, src_ip6_str, &src6) != 1) {
            fprintf(stderr, "Failed to parse source IPv6 address: %s\n", src_ip6_str);
            return 5;
        }
        if (inet_pton(AF_INET6, pfx96_str, &pfx96) != 1) {
            fprintf(stderr, "Failed to parse PFX96 IPv6 address: %s\n", pfx96_str);
            return 6;
        }

        const int mtu4 = atoi(mtu4_str);
        if (mtu4 == 0) {
            fprintf(stderr, "Failed to parse MTU4 '%s'\n", mtu4_str);
            return 7;
        }

        printf("Install on dev[%u/%s] mac[%s] mtu4[%d] ip4[%s] ip6[%s] pfx96[%s/96]\n", ifindex, dev, mac.toString().c_str(), mtu4, local_ip4_str, src_ip6_str, pfx96_str);

        {
            IfIndex key = { .ifindex = ifindex };
            auto res = clat_ifmac_map.writeValue(key, mac, BPF_ANY);
            if (!res.ok()) {
                fprintf(stderr, "Failed to update clat_ifmac_map: %s\n", res.error().message().c_str());
                return 8;
            }
        }

        {
            ClatSrcIpKey key = { .ifindex = ifindex, .local6 = src6 };
            ClatSrcIpValue value = { .pfx96 = pfx96, .local4 = local4 };
            auto res = clat_srcip_map.writeValue(key, value, BPF_ANY);
            if (!res.ok()) {
                fprintf(stderr, "Failed to update clat_srcip_map: %s\n", res.error().message().c_str());
                return 9;
            }
        }

        {
            ClatEgress4Key key = { .iif = ifindex, .local4 = local4 };
            ClatEgress4Value value = { .oif = ifindex, .local6 = src6, .pfx96 = pfx96, .oifIsEthernet = true, .pmtu = (uint16_t)mtu4 };
            auto res = clat_output_map.writeValue(key, value, BPF_ANY);
            if (!res.ok()) {
                fprintf(stderr, "Failed to update clat_output_map: %s\n", res.error().message().c_str());
                return 10;
            }
        }

        {
            ClatIngress6Key key = { .iif = ifindex, .pfx96 = pfx96, .local6 = src6 };
            ClatIngress6Value value = { .oif = ifindex, .local4 = local4 };
            auto res = clat_input_map.writeValue(key, value, BPF_ANY);
            if (!res.ok()) {
                fprintf(stderr, "Failed to update clat_input_map: %s\n", res.error().message().c_str());
                return 11;
            }
        }
    }

    if (argc > 1 && !strcmp(argv[1], "get")) {
        if (argc != 4) {
            fprintf(stderr, "Usage: %s get <IFNAME> <LOCAL_IP4>\n", argv[0]);
            return 1;
        }
        const char* const dev = argv[2];
        const char* const local_ip4_str = argv[3];

        const unsigned ifindex = if_nametoindex(dev);
        if (!ifindex) {
            perror("if_nametoindex failed");
            return 2;
        }

        struct in_addr local4;
        if (inet_pton(AF_INET, local_ip4_str, &local4) != 1) {
            fprintf(stderr, "Failed to parse IPv4 address: %s\n", local_ip4_str);
            return 3;
        }

        ClatEgress4Key key = { .iif = ifindex, .local4 = local4 };
        auto res = clat_output_map.readValue(key);
        if (!res.ok()) {
            fprintf(stderr, "Failed to read clat_output_map: %s\n", res.error().message().c_str());
            return 4;
        }

        auto value = res.value();
        printf("%s\n", ip6_to_string(value.local6).c_str());

        return 0;
    }

    printf("\n");
#define DUMP(map, v...) if (map.isValid()) Dump(#map, map, ## v)
    DUMP(clat_errin_map, true);
    DUMP(clat_errout_map, true);
    DUMP(clat_ifmac_map);
    DUMP(clat_srcip_map);
    DUMP(clat_input_map);
    DUMP(clat_timer_map);
    DUMP(clat_output_map);
#undef DUMP

    return 0;
}
