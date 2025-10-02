// SPDX-License-Identifier: GPL-2.0
// Copyright (C) 2025, Google
// Author: Maciej Żenczykowski

#include <linux/bpf.h>
#include <linux/icmp.h>
#include <linux/icmpv6.h>
#include <linux/if.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/in.h>
#include <linux/in6.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/pkt_cls.h>
#include <linux/swab.h>
#include <linux/udp.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define maybe_unused __attribute__((unused))

#define SECTION(NAME) __attribute__((section(NAME), used))

#define LICENSE(NAME) char _license[] SECTION("license") = (NAME)

// Type-unsafe bpf map functions - avoid if possible.
static void* (*bpf_map_lookup_elem_unsafe)(const void* map, const void* key) = (void*)BPF_FUNC_map_lookup_elem;
static int (*bpf_map_update_elem_unsafe)(const void* map, const void* key, const void* value, unsigned long long flags) = (void*)BPF_FUNC_map_update_elem;
static int (*bpf_map_delete_elem_unsafe)(const void* map, const void* key) = (void*)BPF_FUNC_map_delete_elem;

#define __uint(name, val) int(*(name))[val]
#define __type(name, val) typeof(val) *(name)

// type safe macro to declare a map and related accessor functions
#define DEFINE_BPF_MAP(the_map, TYPE, KeyType, ValueType, num_entries)                    \
    const struct bpf_map_##the_map {                                                      \
        __uint(type, BPF_MAP_TYPE_##TYPE);                                                \
        __type(key, KeyType);                                                             \
        __type(value, ValueType);                                                         \
        __uint(max_entries, (num_entries));                                               \
    } the_map SECTION(".maps");                                                           \
                                                                                          \
    struct ____btf_map_##the_map {                                                        \
        KeyType key;                                                                      \
        ValueType value;                                                                  \
    };                                                                                    \
    struct ____btf_map_##the_map                                                          \
    __attribute__ ((section(".maps." #the_map), used))                                    \
    ____btf_map_##the_map = { };                                                          \
                                                                                          \
    maybe_unused static inline ValueType* bpf_##the_map##_lookup_elem(const KeyType* k) { \
        return bpf_map_lookup_elem_unsafe(&the_map, k);                                   \
    };                                                                                    \
                                                                                          \
    maybe_unused static inline int bpf_##the_map##_update_elem(                           \
            const KeyType* k, const ValueType* v, unsigned long long flags) {             \
        return bpf_map_update_elem_unsafe(&the_map, k, v, flags);                         \
    };                                                                                    \
                                                                                          \
    maybe_unused static inline int bpf_##the_map##_delete_elem(const KeyType* k) {        \
        return bpf_map_delete_elem_unsafe(&the_map, k);                                   \
    };

// static unsigned long long (*bpf_ktime_get_ns)(void) = (void*) BPF_FUNC_ktime_get_ns;
static unsigned long long (*bpf_ktime_get_boot_ns)(void) = (void*)BPF_FUNC_ktime_get_boot_ns;
static int (*bpf_trace_printk)(const char* fmt, int fmt_size, ...) = (void*) BPF_FUNC_trace_printk;
#define bpf_printf(s, n...) bpf_trace_printk(s, sizeof(s), ## n)

static int (*bpf_skb_pull_data)(struct __sk_buff* skb, __u32 len) = (void*)BPF_FUNC_skb_pull_data;
static int (*bpf_skb_load_bytes)(const struct __sk_buff* skb, int off, void* to, int len) = (void*)BPF_FUNC_skb_load_bytes;
// static int (*bpf_skb_load_bytes_relative)(const struct __sk_buff* skb, int off, void* to, int len, int start_hdr) = (void*)BPF_FUNC_skb_load_bytes_relative;
// static int (*bpf_skb_store_bytes)(struct __sk_buff* skb, __u32 offset, const void* from, __u32 len, __u64 flags) = (void*)BPF_FUNC_skb_store_bytes;
static int64_t (*bpf_csum_diff)(__be32* from, __u32 from_size, __be32* to, __u32 to_size, __wsum seed) = (void*)BPF_FUNC_csum_diff;
static int64_t (*bpf_csum_update)(struct __sk_buff* skb, __wsum csum) = (void*)BPF_FUNC_csum_update;
static int (*bpf_skb_change_proto)(struct __sk_buff* skb, __be16 proto, __u64 flags) = (void*)BPF_FUNC_skb_change_proto;
// static int (*bpf_l3_csum_replace)(struct __sk_buff* skb, __u32 offset, __u64 from, __u64 to, __u64 flags) = (void*)BPF_FUNC_l3_csum_replace;
// static int (*bpf_l4_csum_replace)(struct __sk_buff* skb, __u32 offset, __u64 from, __u64 to, __u64 flags) = (void*)BPF_FUNC_l4_csum_replace;
static int (*bpf_redirect)(__u32 ifindex, __u64 flags) = (void*)BPF_FUNC_redirect;
// static int (*bpf_skb_change_head)(struct __sk_buff* skb, __u32 head_room, __u64 flags) = (void*)BPF_FUNC_skb_change_head;
static int (*bpf_skb_adjust_room)(struct __sk_buff* skb, __s32 len_diff, __u32 mode, __u64 flags) = (void*)BPF_FUNC_skb_adjust_room;

// Only supports little endian architectures
#define htons(x) (__builtin_constant_p(x) ? ___constant_swab16(x) : __builtin_bswap16(x))
#define htonl(x) (__builtin_constant_p(x) ? ___constant_swab32(x) : __builtin_bswap32(x))
#define ntohs(x) htons(x)
#define ntohl(x) htonl(x)

#define offsetof(struct_type, field) __builtin_offsetof(struct_type, field)

// Offsets from beginning of L3 (IPv4/IPv6) header
#define IP4_OFFSET(field) offsetof(struct iphdr, field)
//#define IP6_OFFSET(field) offsetof(struct ipv6hdr, field)

// Offsets from beginning of L4 (TCP/UDP) header
//#define TCP_OFFSET(field) offsetof(struct tcphdr, field)
//#define UDP_OFFSET(field) offsetof(struct udphdr, field)

// IP flags. (from kernel's include/net/ip.h)
//#define IP_CE      0x8000  // Flag: "Congestion" (reserved 'evil bit')
#define IP_DF      0x4000  // Flag: "Don't Fragment"
#define IP_MF      0x2000  // Flag: "More Fragments"
//#define IP_OFFSET  0x1FFF  // "Fragment Offset" part

// from kernel's include/net/ipv6.h
struct frag_hdr {
    __u8   nexthdr;
    __u8   reserved;        // always zero
    __be16 frag_off;        // 13 bit offset, 2 bits zero, 1 bit "More Fragments"
    __be32 identification;
};

// try to make the first 'len' header bytes readable/writable via direct packet access
// (note: AFAIK there is no way to ask for only direct packet read without also getting write)
static inline void try_make_writable(struct __sk_buff* skb, int len) {
    if (len > skb->len) len = skb->len;
    if (skb->data_end - skb->data < len) bpf_skb_pull_data(skb, len);
}

#include "clatd.h"

// Unfortunately need a separate map for ingress/egress errors due to how the
// loading process works (it cannot share a single map across 2 diff tc programs atm)
DEFINE_BPF_MAP(clat_errin_map, ARRAY, ClatErrorKey, uint64_t, BPF_CLAT_ERR__MAX)
DEFINE_BPF_MAP(clat_errout_map, ARRAY, ClatErrorKey, uint64_t, BPF_CLAT_ERR__MAX)
DEFINE_BPF_MAP(clat_ifmac_map, HASH, IfIndex, MacAddress, 16)  // ifindex -> mac
DEFINE_BPF_MAP(clat_srcip_map, HASH, ClatSrcIpKey, ClatSrcIpValue, 16)
DEFINE_BPF_MAP(clat_input_map, HASH, ClatIngress6Key, ClatIngress6Value, 16)
DEFINE_BPF_MAP(clat_timer_map, ARRAY, uint32_t, ClatTimerValue, 1)
DEFINE_BPF_MAP(clat_output_map, HASH, ClatEgress4Key, ClatEgress4Value, 16)

#define DIRLONG INGRESS
#define DIRSHORT in

SECTION("schedcls/clat_ingress")
int clat_ingress(struct __sk_buff* skb) {
    const bool is_ethernet = true;

    // Require ethernet dst mac address to be our unicast address.
    // PACKET_ HOST=0 BROADCAST=1 MULTICAST=2 OTHERHOST=3 OUTGOING=4 LOOPBACK=5 USER=6 KERNEL=7 FASTROUTE=6
    if (is_ethernet && (skb->pkt_type == PACKET_OTHERHOST)) TC_PUNT(OTHERHOST); // do not log
    if (is_ethernet && (skb->pkt_type == PACKET_MULTICAST)) TC_PUNT(MULTICAST); // do not log
    if (is_ethernet && (skb->pkt_type == PACKET_BROADCAST)) TC_PUNT(BROADCAST); // do not log
    if (is_ethernet && (skb->pkt_type == PACKET_LOOPBACK)) TC_PUNT(LOOPBACK); // do not log
    if (is_ethernet && (skb->pkt_type == PACKET_OUTGOING)) TC_PUNT(OUTGOING); // do not log
    if (is_ethernet && (skb->pkt_type != PACKET_HOST)) { bpf_printf("nat64 pkt_type:%d", skb->pkt_type); TC_PUNT(NOT_HOST); };

    // Must be meta-ethernet IPv6 frame
    if (skb->protocol != htons(ETH_P_IPV6)) { bpf_printf("nat64 protocol:%04x", ntohs(skb->protocol)); TC_DROP(NOT_IPV6); };

    const int l2_header_size = is_ethernet ? sizeof(struct ethhdr) : 0;

    // Not clear if this is actually necessary considering we use DPA (Direct Packet Access),
    // but we need to make sure we can read the IPv6 header reliably so that we can set
    // skb->mark = 0xDeadC1a7 for packets we fail to offload.
    try_make_writable(skb, l2_header_size + sizeof(struct ipv6hdr) + 8 + 4); // should this be 4? GRE?

    void* data = (void*)(long)skb->data;
    const void* data_end = (void*)(long)skb->data_end;
    const struct ethhdr* const eth = is_ethernet ? data : NULL;  // used iff is_ethernet
    const struct ipv6hdr* const ip6 = is_ethernet ? (void*)(eth + 1) : data;

    // Must have (ethernet and) ipv6 header
    if (data + l2_header_size + sizeof(*ip6) + 4 > data_end) { bpf_printf("nat64 short:%d", data_end - data); TC_PUNT(TOO_SHORT); };

    // Ethertype - if present - must be IPv6
    if (is_ethernet && (eth->h_proto != htons(ETH_P_IPV6))) { bpf_printf("nat64 !IPv6:%04x", ntohs(eth->h_proto)); TC_PUNT(WRONG_ETHERTYPE); };

    // IP version must be 6
    if (ip6->version != 6) { bpf_printf("nat64 !IPv6:%d", ip6->version); TC_PUNT(WRONG_IP6VERSION); };

    // Maximum IPv6 payload length that can be translated to IPv4
    // Note: technically this check is too strict for an IPv6 fragment,
    // which by virtue of stripping the extra 8 byte fragment extension header,
    // could thus be 8 bytes larger and still fit in an ipv4 packet post
    // translation.  However... who ever heard of receiving ~64KB frags...
    // fragments are kind of by definition smaller than ingress device mtu,
    // and thus, on the internet, very very unlikely to exceed 1500 bytes.
    if (ntohs(ip6->payload_len) > 0xFFFF - sizeof(struct iphdr)) { bpf_printf("nat64 long:%d", ntohs(ip6->payload_len)); TC_PUNT(TOO_LONG); };

    ClatIngress6Key k = {
        .iif = skb->ifindex,
        .pfx96.in6_u.u6_addr32 =
            {
                ip6->saddr.in6_u.u6_addr32[0],
                ip6->saddr.in6_u.u6_addr32[1],
                ip6->saddr.in6_u.u6_addr32[2],
            },
        .local6 = ip6->daddr,
    };

    ClatIngress6Value* v = bpf_clat_input_map_lookup_elem(&k);

    if (!v) {
        //bpf_printf("nat64:A");
        if (is_ethernet && ip6->nexthdr == IPPROTO_ICMPV6) {
            struct __attribute__((__packed__)) { //packed is critical
                MacAddress eth_dst_mac;
                MacAddress eth_src_mac;
                __be16 ethertype;
                struct ipv6hdr ip6;
                struct icmp6hdr icmp6;
                struct in6_addr tgt;
                __u8 opt;
                __u8 len;
                MacAddress mac;
            } *pkt = (void*)(long)data;
            //bpf_printf("nat64:B %d %d", pkt->icmp6.icmp6_type, pkt->icmp6.icmp6_code);
            if (pkt->icmp6.icmp6_type == 135 && pkt->icmp6.icmp6_code == 0) {
                //bpf_printf("nat64:C");
                ClatSrcIpKey k2 = {
                    .ifindex = skb->ifindex,
                    .local6 = ip6->daddr,
                };
                ClatSrcIpValue* v2 = bpf_clat_srcip_map_lookup_elem(&k2);
                if (v2) {
                    //bpf_printf("nat64:D");
                    IfIndex k3 = {.ifindex = skb->ifindex};
                    MacAddress* m = bpf_clat_ifmac_map_lookup_elem(&k3);
                    //bpf_printf("nat64 icmpv6 ns [%d-14-40:%d] %d", skb->len, skb->len - ETH_HLEN - 40, !!m);
// ether: dst:[70cf49322d32] src:[b0c19e98657b] type(ipv6):[86dd] (len 86)
// ip6: v[6] flowlbl[00000] tclass[00] paylen(32)[0020] nexthdr(ICMP6)[3a] hl(255)[ff] src[fe80::b2c1:9eff:fe98:657b] dst[2a00:f41:5834:d37:547a:79ec:75fc:dcf1]
// icmp6: type(NS):[87] code:[00] csum:[8e74] flags(none)[00000000] tgt[2a00:f41:5834:d37:547a:79ec:75fc:dcf1] opt(src laddr)[01] len(8)[01] mac[b0c19e98657b]

// UNICAST->MULTICAST: ether-dst:[3333fffcdcf1] ip6-dst[ff02::1:fffc:dcf1] icmp6-csum:[7283]

// ether: dst:[b0c19e98657b] src:[70cf49322d32] type(ipv6):[86dd] (len 86)
// ip6: v[6] flowlbl[00000] tclass[00] paylen(32)[0020] nexthdr(ICMP6)[3a] hl(255)[ff] src[fe80::7a78:41ec:9938:8d46] dst[fe80::b2c1:9eff:fe98:657b]
// icmp6: type(NA):[88] code:[00] csum:[f8b2] flags(solicited)[40000000] tgt[2a00:f41:5834:d37:547a:79ec:75fc:dcf1] opt(dst laddr)[02] len(8)[01] mac[70cf49322d32]

                    if (!m || skb->len != 86) TC_DROP(ICMPV6_1);
                    //bpf_printf("nat64:E");
                    if ((void*)(pkt + 1) > data_end) TC_DROP(ICMPV6_2);
                    //bpf_printf("nat64:F");
                    if (pkt->ip6.payload_len != htons(32)) TC_DROP(ICMPV6_3);
                    //bpf_printf("nat64:G");
                    if (memcmp(&pkt->tgt, &k2.local6, 16)) TC_DROP(ICMPV6_4);
                    pkt->eth_dst_mac = pkt->mac;
                    pkt->eth_src_mac = *m;
                    pkt->ethertype = htons(ETH_P_IPV6);
                    pkt->ip6.version = 6;
                    //...ip6 fields: flowlabel, tclass
                    pkt->ip6.priority = 0; // top 4 bits of tclass
                    pkt->ip6.flow_lbl[0] = 0;  // bottom 4 bits of tclass
                    pkt->ip6.flow_lbl[1] = 0;
                    pkt->ip6.flow_lbl[2] = 0;
                    pkt->ip6.payload_len = htons(32);
                    pkt->ip6.nexthdr = IPPROTO_ICMPV6;
                    pkt->ip6.hop_limit = 0xFF;
                    pkt->ip6.daddr = pkt->ip6.saddr;
                    //pkt->ip6.saddr = k2.local6;  Instead generate from mac, but this is not necessarily the right fe80 addr... with privacy
                    pkt->ip6.saddr.s6_addr32[0] = htonl(0xFE800000);
                    pkt->ip6.saddr.s6_addr32[1] = 0;
                    pkt->ip6.saddr.s6_addr[8] = m->mac8[0] ^ 0x02;
                    pkt->ip6.saddr.s6_addr[9] = m->mac8[1];
                    pkt->ip6.saddr.s6_addr[10] = m->mac8[2];
                    pkt->ip6.saddr.s6_addr[11] = 0xff;
                    pkt->ip6.saddr.s6_addr[12] = 0xfe;
                    pkt->ip6.saddr.s6_addr[13] = m->mac8[3];
                    pkt->ip6.saddr.s6_addr[14] = m->mac8[4];
                    pkt->ip6.saddr.s6_addr[15] = m->mac8[5];
                    pkt->icmp6.icmp6_type = 136;
                    pkt->icmp6.icmp6_code = 0;
                    pkt->icmp6.icmp6_cksum = 0;
                    pkt->icmp6.icmp6_dataun.un_data32[0] = 0;
                    pkt->icmp6.icmp6_dataun.u_nd_advt.router = 0; // ?router?
                    pkt->icmp6.icmp6_dataun.u_nd_advt.solicited = 1;
                    pkt->tgt = k2.local6;
                    pkt->opt = 2;
                    pkt->len = 1;
                    memcpy(pkt->mac.mac8, m->mac8, ETH_ALEN);
                    uint64_t cs = bpf_csum_diff(NULL, 0, (void*)&pkt->ip6.saddr, /*64*/ (char*)(pkt+1) - (char*)(&pkt->ip6.saddr), 0);
                    //bpf_printf("nat64:H cs:%08x", cs);
                    cs += pkt->ip6.payload_len;
                    cs += pkt->ip6.nexthdr << 8;
                    cs = (cs >> 16) + (cs & 0xFFFF);
                    cs = (cs >> 16) + cs;
                    pkt->icmp6.icmp6_cksum = ~cs;
                    uint32_t k4 = 0;
                    ClatTimerValue *v4 = bpf_clat_timer_map_lookup_elem(&k4);
                    if (v4) {
                        //__u64 now = bpf_ktime_get_ns();
                        __u64 now = bpf_ktime_get_boot_ns();
                        __u64 delta = now - v4->last_time;
                        bpf_printf("nat64: reply to NS%d (%d.%03ds)", v4->count, delta / 1000000000, delta % 1000000000 / 1000000);
                        v4->count++;
                        v4->last_time = now;
                        bpf_clat_timer_map_update_elem(&k4, v4, BPF_EXIST);
                    } else {
                        //bpf_printf("nat64: replying to NS (!?).");  // impossible
                    }
                    TC_COUNT(ICMPV6_NS_NA);
                    return bpf_redirect(skb->ifindex, 0 /* this is effectively BPF_F_EGRESS */);
                }
            }
        }
        TC_PUNT(NOT_CLAT);
    }

    __u8 proto = ip6->nexthdr;
    __be16 ip_id = 0;
    __be16 frag_off = htons(IP_DF);
    __u16 tot_len = ntohs(ip6->payload_len) + sizeof(struct iphdr);  // cannot overflow, see above

    if (proto == IPPROTO_FRAGMENT) {
        // Must have (ethernet and) ipv6 header and ipv6 fragment extension header
        if (data + l2_header_size + sizeof(*ip6) + sizeof(struct frag_hdr) > data_end) {
            bpf_printf("nat64 frag hdr out of bounds (len:%d %d)", skb->len, data_end - data);
            TC_PUNT(FRAG_OOB);
        }

        //bpf_printf("nat64 frag in");

        const struct frag_hdr *frag = (const struct frag_hdr *)(ip6 + 1);
        proto = frag->nexthdr;
        // RFC6145: use bottom 16-bits of network endian 32-bit IPv6 ID field for 16-bit IPv4 field.
        // this is equivalent to: ip_id = htons(ntohl(frag->identification));
        ip_id = frag->identification >> 16;
        // Conversion of 16-bit IPv6 frag offset to 16-bit IPv4 frag offset field.
        // IPv6 is '13 bits of offset in multiples of 8' + 2 zero bits + more fragment bit
        // IPv4 is zero bit + don't frag bit + more frag bit + '13 bits of offset in multiples of 8'
        frag_off = ntohs(frag->frag_off);
        frag_off = ((frag_off & 1) << 13) | (frag_off >> 3);
        frag_off = htons(frag_off);
        // Note that by construction tot_len is guaranteed to not underflow here
        tot_len -= sizeof(struct frag_hdr);
        // This is a badly formed IPv6 packet with less payload than the size of an IPv6 Frag EH
        if (tot_len < sizeof(struct iphdr)) TC_PUNT(FRAG_MALFORMED);
    }

    switch (proto) {
        case IPPROTO_TCP:      // For TCP, UDP & UDPLITE the checksum neutrality of the chosen
        case IPPROTO_UDP:      // IPv6 address means there is no need to update their checksums.
        case IPPROTO_UDPLITE:  //
        case IPPROTO_GRE:      // We do not need to bother looking at GRE/ESP headers,
        case IPPROTO_ESP:      // since there is never a checksum to update.
            break;

        case IPPROTO_ICMPV6: if ((frag_off & htons(0x1FFF)) == 0) {
            bool is_fragment = !!(frag_off != htons(IP_DF));
            //if (frag_off != htons(IP_DF)) { bpf_printf("nat64 frag icmpv6"); TC_DROP(); }
            struct icmp6hdr *ih = (struct icmp6hdr*)(ip6 + 1);
            if (is_fragment) {
                ih++;
//              try_make_writable(skb, ETH_HLEN + 40 + 8 + 4);
                if (data + ETH_HLEN + sizeof(*ip6) + 8 + sizeof(*ih) - 4 > data_end) { bpf_printf("nat64 icmp6 frag len:%d %d", skb->len, data_end - data); TC_DROP(ICMPV6_OOB); }
            }
            //bpf_printf("nat64 icmpv6 [%d/%d] %04x", ih->icmp6_type, ih->icmp6_code, ih->icmp6_cksum);
            __u8 new_type;
            __u8 new_code = ih->icmp6_code;
            switch (ih->icmp6_type) {
              case ICMPV6_ECHO_REQUEST: new_type = ICMP_ECHO;          break;
              case ICMPV6_ECHO_REPLY:   new_type = ICMP_ECHOREPLY;     break;
              case ICMPV6_TIME_EXCEED:  new_type = ICMP_TIME_EXCEEDED; break;
              case ICMPV6_DEST_UNREACH: new_type = ICMP_DEST_UNREACH;
                switch (ih->icmp6_code) {
                  case ICMPV6_NOROUTE:        new_code = ICMP_HOST_UNREACH;        break;
                  case ICMPV6_ADM_PROHIBITED: new_code = ICMP_HOST_ANO;            break;
                  case ICMPV6_NOT_NEIGHBOUR:  new_code = ICMP_HOST_UNREACH;        break;
                  case ICMPV6_ADDR_UNREACH:   new_code = ICMP_HOST_UNREACH;        break;
                  case ICMPV6_PORT_UNREACH:   new_code = ICMP_PORT_UNREACH;        break;
                  default: bpf_printf("nat64 icmp6 unknown code:%d", ih->icmp6_code); TC_DROP(ICMPV6_UNKNOWN_CODE);
                }
                break;
              default: bpf_printf("nat64 icmp6 unknown type:%d", ih->icmp6_type); TC_DROP(ICMPV6_UNKNOWN_TYPE);
            }
            //uint64_t chk = 0;
            //chk += ip6->saddr.s6_addr32[0];
            //chk += ip6->saddr.s6_addr32[1];
            //chk += ip6->saddr.s6_addr32[2];
            //!//chk += ip6->saddr.s6_addr32[3];
            //chk += ip6->daddr.s6_addr32[0];
            //chk += ip6->daddr.s6_addr32[1];
            //chk += ip6->daddr.s6_addr32[2];
            //chk += ip6->daddr.s6_addr32[3];
            //chk += 0xFFFFFFFF - v->local4.s_addr;
            //chk = (chk >> 16) + (chk & 0xffff);
            //chk = (chk >> 16) + (chk & 0xffff);
            //bpf_printf("new_type:%d [%x]", new_type, chk);
            proto = IPPROTO_ICMP;
            uint64_t cs = ih->icmp6_cksum + 0xFFFF + ip6->saddr.s6_addr32[3] + v->local4.s_addr + ih->icmp6_type - new_type + (ih->icmp6_code << 8) - (new_code << 8) + (IPPROTO_ICMPV6 << 8) + htons(is_fragment ? 1460-28-28+73+8 : tot_len - 20);
            ih->icmp6_type = new_type;
            ih->icmp6_code = new_code;
            cs = (cs >> 16) + (cs & 0xFFFF);
            cs = (cs >> 16) + (cs & 0xFFFF);
            cs = (cs >> 16) + cs;
            ih->icmp6_cksum = cs;
            break; // return TC_ACT_SHOT;
        } else proto = IPPROTO_ICMP;
        break;

        default:  // do not know how to handle anything else
            bpf_printf("nat64 proto: %d", proto);
            TC_DROP(UNKNOWN_PROTOCOL);
    }

    struct ethhdr eth2;  // used iff is_ethernet
    if (is_ethernet) {
        eth2 = *eth;                     // Copy over the ethernet header (src/dst mac)
        eth2.h_proto = htons(ETH_P_IP);  // But replace the ethertype
    }

    struct iphdr ip = {
        .version = 4,                                                      // u4
        .ihl = sizeof(struct iphdr) / sizeof(__u32),                       // u4
        .tos = (ip6->priority << 4) + (ip6->flow_lbl[0] >> 4),             // u8
        .tot_len = htons(tot_len),                                         // be16
        .id = ip_id,                                                       // be16
        .frag_off = frag_off,                                              // be16
        .ttl = ip6->hop_limit,                                             // u8
        .protocol = proto,                                                 // u8
        .check = 0,                                                        // u16
        .saddr = ip6->saddr.in6_u.u6_addr32[3],                            // be32
        .daddr = v->local4.s_addr,                                         // be32
    };

    // Calculate the IPv4 one's complement checksum of the IPv4 header.
    __wsum sum4 = 0;
    for (int i = 0; i < sizeof(ip) / sizeof(__u16); ++i) {
        sum4 += ((__u16*)&ip)[i];
    }
    // Note that sum4 is guaranteed to be non-zero by virtue of ip.version == 4
    sum4 = (sum4 & 0xFFFF) + (sum4 >> 16);  // collapse u32 into range 1 .. 0x1FFFE
    sum4 = (sum4 & 0xFFFF) + (sum4 >> 16);  // collapse any potential carry into u16
    ip.check = (__u16)~sum4;                // sum4 cannot be zero, so this is never 0xFFFF

    // Calculate the *negative* IPv6 16-bit one's complement checksum of the IPv6 header.
    __wsum sum6 = 0;
    // We'll end up with a non-zero sum due to ip6->version == 6 (which has '0' bits)
    for (int i = 0; i < sizeof(*ip6) / sizeof(__u16); ++i) {
        sum6 += ~((__u16*)ip6)[i];  // note the bitwise negation
    }

    // Note that there is no L4 checksum update: we are relying on the checksum neutrality
    // of the ipv6 address chosen by netd's ClatdController.

    // Packet mutations begin - point of no return, but if this first modification fails
    // the packet is probably still pristine, so let clatd handle it.
    if (bpf_skb_change_proto(skb, htons(ETH_P_IP), 0)) {
        bpf_printf("nat64 change proto");
        TC_DROP(CHANGE_PROTO);
    }

    // This takes care of updating the skb->csum field for a CHECKSUM_COMPLETE packet.
    //
    // In such a case, skb->csum is a 16-bit one's complement sum of the entire payload,
    // thus we need to subtract out the ipv6 header's sum, and add in the ipv4 header's sum.
    // However, by construction of ip.check above the checksum of an ipv4 header is zero.
    // Thus we only need to subtract the ipv6 header's sum, which is the same as adding
    // in the sum of the bitwise negation of the ipv6 header.
    //
    // bpf_csum_update() always succeeds if the skb is CHECKSUM_COMPLETE and returns an error
    // (-ENOTSUPP) if it isn't.  So we just ignore the return code.
    //
    // if (skb->ip_summed == CHECKSUM_COMPLETE)
    //   return (skb->csum = csum_add(skb->csum, csum));
    // else
    //   return -ENOTSUPP;
    bpf_csum_update(skb, sum6);

    if (frag_off != htons(IP_DF)) {
        // If we're converting an IPv6 Fragment, we need to trim off 8 more bytes
        // We're beyond recovery on error here... but hard to imagine how this could fail.
        if (bpf_skb_adjust_room(skb, -(__s32)sizeof(struct frag_hdr), BPF_ADJ_ROOM_NET, /*flags*/0))
            TC_DROP(ADJUST_ROOM);
    }

    try_make_writable(skb, l2_header_size + sizeof(struct iphdr));

    // bpf_skb_change_proto() invalidates all pointers - reload them.
    data = (void*)(long)skb->data;
    data_end = (void*)(long)skb->data_end;

    // I cannot think of any valid way for this error condition to trigger, however I do
    // believe the explicit check is required to keep the in kernel ebpf verifier happy.
    if (data + l2_header_size + sizeof(struct iphdr) > data_end) TC_DROP(OOB);

    if (is_ethernet) {
        struct ethhdr* new_eth = data;

        // Copy over the updated ethernet header
        *new_eth = eth2;

        // Copy over the new ipv4 header.
        *(struct iphdr*)(new_eth + 1) = ip;
    } else {
        // Copy over the new ipv4 header without an ethernet header.
        *(struct iphdr*)data = ip;
    }

    // Count successfully translated packet
    __sync_fetch_and_add(&v->packets, 1);
    __sync_fetch_and_add(&v->bytes, skb->len - l2_header_size);

    // Redirect, possibly back to same interface, so tcpdump sees packet twice.
    if (v->oif) {
        TC_COUNT(XLAT_REDIRECT);
        return bpf_redirect(v->oif, BPF_F_INGRESS);
    }

    // Just let it through, tcpdump will not see IPv4 packet.
    TC_COUNT(XLAT);
    return TC_ACT_PIPE;
}

#undef DIRSHORT
#undef DIRLONG

#define DIRLONG EGRESS
#define DIRSHORT out

SECTION("schedcls/clat_egress")
int clat_egress(struct __sk_buff* skb) {
    // Must be meta-ethernet IPv4 frame
    if (skb->protocol != htons(ETH_P_IP)) TC_PUNT(NOT_IPV4);

    // Possibly not needed, but for consistency with nat64 up above
    // TCP(20..60)/UDP(8)/UDPLITE(8)/ESP(8+)/ICMP4(8)/GRE(4+)
    try_make_writable(skb, ETH_HLEN + sizeof(struct iphdr) + 8); // clamps to skb->len

    void* data = (void*)(long)skb->data;
    const void* data_end = (void*)(long)skb->data_end;
    const struct iphdr* /*const*/ ip4 = data + ETH_HLEN;

    // Must have ipv4 header
    if (data + ETH_HLEN + sizeof(*ip4) + 4 > data_end) TC_DROP(TOO_SHORT);

    // IP version must be 4
    if (ip4->version != 4) TC_DROP(WRONG_IP4VERSION);

    // We cannot handle IP options, just standard 20 byte == 5 dword minimal IPv4 header
    if (ip4->ihl != 5) TC_DROP(IPV4_OPTIONS);

    // Packet must not be multicast, if it is just outright drop it.
    if ((ip4->daddr & htonl(0xf0000000)) == htonl(0xe0000000)) TC_DROP(IPV4_MULTICAST);

    // Packet must not be broadcast, if it is just outright drop it.
    if (ip4->daddr == 0xFFFFFFFF) TC_DROP(IPV4_BROADCAST);

    // Calculate the IPv4 one's complement checksum of the IPv4 header.
    __wsum sum4 = 0;
    for (int i = 0; i < sizeof(*ip4) / sizeof(__u16); ++i) {
        sum4 += ((__u16*)ip4)[i];
    }
    // Note that sum4 is guaranteed to be non-zero by virtue of ip4->version == 4
    sum4 = (sum4 & 0xFFFF) + (sum4 >> 16);  // collapse u32 into range 1 .. 0x1FFFE
    sum4 = (sum4 & 0xFFFF) + (sum4 >> 16);  // collapse any potential carry into u16
    // for a correct checksum we should get *a* zero, but sum4 must be positive, ie 0xFFFF
    if (sum4 != 0xFFFF) TC_DROP(IPV4_WRONG_CHECKSUM);

    // Minimum IPv4 total length is the size of the header
    if (ntohs(ip4->tot_len) < sizeof(*ip4)) TC_DROP(IPV4_TOO_SHORT);

    ClatEgress4Key k = {
        .iif = skb->ifindex,
        .local4.s_addr = ip4->saddr,
    };

    ClatEgress4Value* v = bpf_clat_output_map_lookup_elem(&k);

    if (!v) TC_DROP(NOT_CLAT);

    if (skb->len > ETH_HLEN + v->pmtu) {
        bpf_printf("nat46 len:%d > eth:%d mtu:%d", skb->len, ETH_HLEN, v->pmtu);
        bpf_printf("nat46 gso_size:%d gso_segs:%d wire_len:%d", skb->gso_size, skb->gso_segs, skb->wire_len);
        // skb_shared_info u16 gso_size, gso_segs (not always filled in [UFO!]), uint gso_type
        // skb->wire_len is skb->cb (as qdisc_skb_cb) ->pkt_len
        // dd if=/dev/urandom count=1 bs=4096 > /dev/tcp/zoom.elentari.org/22
        // 14 ether + 20 ipv4 + 20 tcp + 12 tcp options == 66
        // nat46 len:2482 > eth:14 mtu:1432 gso_size:1208 gso_segs:2 wire_len:2548 $[2482-1208]==1274 $[2482-1208*2]==66 $[2548-2482]==66
        // nat46 len:1746 > eth:14 mtu:1432 gso_size:1208 gso_segs:2 wire_len:1812 $[2746-1208]==1538                    $[1812-1746]==66
        if (skb->gso_segs > 1) {
            int hdr = (skb->wire_len - skb->len) / (skb->gso_segs - 1);
            int last = skb->len - hdr - (skb->gso_segs - 1) * skb->gso_size;
            if (last == skb->gso_size) {
                bpf_printf("nat46 %d * [%d+%d]", skb->gso_segs, hdr, skb->gso_size);
            } else {
                bpf_printf("nat46 %d * [%d+%d]", skb->gso_segs-1, hdr, skb->gso_size);
                bpf_printf("nat46     [%d+%d]", hdr, last);
            }
            int need_mtu = hdr + skb->gso_size;
            if (need_mtu > ETH_HLEN + v->pmtu) bpf_printf("nat46 (gso) mtu [%d>%d] exceeded!", need_mtu, ETH_HLEN + v->pmtu);
            // Note this is on Orange PL, so TCP MSS clamped (to 1220 in ipv4 apparently, so 1220 + 20 tcp + 20 ipv4 = 1260 ipv4 mtu = 1280 (1288) ipv6 mtu)
            // 66 == 14 ethernet + 20 ipv4 + 20 tcp + 12 timestamp
            // 66 + 1208 = 14 ethernet + 1260 mtu
            //
            // $ dd if=/dev/urandom count=1 bs=4096 > /dev/tcp/zoom.elentari.org/22
            //   nat46 len:2482 > eth:14 mtu:1432
            //   nat46 gso_size:1208 gso_segs:2 wire_len:2548
            //   nat46 2 * [66+1208]
            //   nat46 len:1746 > eth:14 mtu:1432
            //   nat46 gso_size:1208 gso_segs:2 wire_len:1812
            //   nat46 1 * [66+1208]
            //   nat46     [66+472]
            //
            // $ dd if=/dev/urandom count=1 bs=4096 > /dev/tcp/8.8.8.8/853
            //   nat46 len:4162 > eth:14 mtu:1432
            //   nat46 gso_size:1208 gso_segs:4 wire_len:4360
            //   nat46 3 * [66+1208]
            //   nat46     [66+472]
        } else if (skb->gso_size) {
            bpf_printf("nat46 (?gso: gso_segs(%d) <= 1) mtu exceeded!", skb->gso_size);
        } else {
            bpf_printf("nat46 (non-gso) mtu exceeded!");
        }
    }

    bool is_fragment = !!(ip4->frag_off & ~htons(IP_DF));
    __u8 proto = ip4->protocol;
    if (ip4->frag_off & htons(0x1FFF)) {
        if (ip4->frag_off & htons(IP_MF))
            bpf_printf("nat46 middle  fragment proto:%d", proto);
        else
            bpf_printf("nat46 final   fragment proto:%d", proto);
        if (proto == IPPROTO_ICMP) proto = IPPROTO_ICMPV6;
    } else {
        if (is_fragment) bpf_printf("nat46 initial fragment proto:%d", proto);
        switch (proto) {
            case IPPROTO_TCP:      // For TCP, UDP & UDPLITE the checksum neutrality of the chosen
            case IPPROTO_UDPLITE:  // IPv6 address means there is no need to update their checksums.
            case IPPROTO_GRE:      // We do not need to bother looking at GRE/ESP headers,
            case IPPROTO_ESP:      // since there is never a checksum to update.
                break;

            case IPPROTO_UDP: {    // See above comment, but must also have UDP header...
                if (data + ETH_HLEN + sizeof(*ip4) + sizeof(struct udphdr) > data_end) { bpf_printf("nat46 short2:%d", data_end - data); TC_DROP(UDP4_TOO_SHORT); };
                struct udphdr* uh = (struct udphdr*)(ip4 + 1);
                // If IPv4/UDP checksum is 0 then fallback to clatd so it can calculate the
                // checksum.  Otherwise the network or more likely the NAT64 gateway might
                // drop the packet because in most cases IPv6/UDP packets with a zero checksum
                // are invalid. See RFC 6935.  TODO: calculate checksum via bpf_csum_diff() <-- how?!?
                //
                // How do we know we don't have csum offload with partial checksum zero?
                // IMHO partial checksum should never be 0 (sum includes udp proto '17', thus
                // is non-zero pre-collapse, and thus post collapse should be as well, unless extra
                // steps taken to force 0xFFFF back to 0, which seems like a waste of cpu cycles)
                if (!uh->check) {
                    // cannot calculate udp payload csum without defrag
                    if (is_fragment) { bpf_printf("nat46 udp !csum - fragmented :-("); TC_DROP(UDP4_CSUM0_FRAG); }
                    uint16_t udp_len = ntohs(uh->len);
                    bpf_printf("nat46 udp !csum [sport:%d -> dport:%d, len:%u]", ntohs(uh->source), ntohs(uh->dest), udp_len);
                    // 1500 ethernet mtu - 28 translation overhead - 20 ipv4 header
                    //if (udp_len > 1500 - 28 - 20) { bpf_printf("nat46 udp !csum - too long :-("); TC_DROP(); }  // technically could happen with offloads or pre-defrag or sth...

                    // in theory we should only checksum the udp payload length, but that fails below...
                    //if (ntohs(ip4->tot_len) != sizeof(*ip4) + udp_len) { bpf_printf("nat46 udp !csum ip & udp payload size mismatch"); TC_DROP(); }

                    // CHUNK_SIZE must be even (for bpf_csum_diff() result sanity), or even a multiple of 4 (per argument ptr type of bpf_csum_diff)
                    // and should be large (for efficiency), but not too large or we'll overflow the eBPF stack (512 bytes I believe)
                    #define CHUNK_SIZE 256
                    // CHUNK_SIZE * NUM_STEPS should be >= maximum IPv4 packet size (65535) minus 12 (ie. 65523, which is still ~65536)
                    // Though note that in practice IPv4/UDP !csum packets are AFAIK almost exclusively used by tunnels/vpns and thus are not >pmtu,
                    // so we really only need to cover 1500 mtu - 28 xlat overhead - 12 partial ipv4 header = 1460 bytes
                    // Thus we could in theory do:
                    //   NUM_STEPS == 256                  CHUNK_SIZE=256   256*256 = 65536 >= 65535-12 = 65523
                    //   NUM_STEPS == 222                  CHUNK_SIZE=296   222*296 = 65712 >= 65535-12 = 65523
                    //   NUM_STEPS == 6  1460/6=243.333 -> CHUNK_SIZE=244 (or 256) so we cover 6 * 244 (or 256) = 1464 (or 1536) >= 1460
                    //   NUM_STEPS == 5  1460/5=292     -> CHUNK_SIZE=292  <-- max that fits appears to be CHUNK_SIZE=~298
                    //   NUM_STEPS == 4  1460/4=365     -> CHUNK_SIZE=368  <-- appears to not fit on the stack
                    //   NUM_STEPS == 3  1460/3=486.667 -> CHUNK_SIZE=488  <-- no chance of it fitting on the stack
                    #define NUM_STEPS 256

                    _Static_assert(CHUNK_SIZE > 0, "FATAL: CHUNK_SIZE must be > 0");
                    _Static_assert((CHUNK_SIZE & 1) == 0, "FATAL: CHUNK_SIZE *MUST* be even");
                    _Static_assert((CHUNK_SIZE & 3) == 0, "WARNING: CHUNK_SIZE *SHOULD* be a multiple of 4, adjust u32 buf[] below");
                    _Static_assert(NUM_STEPS > 0, "FATAL: NUM_STEPS must be > 0");
                    _Static_assert(12 + CHUNK_SIZE * NUM_STEPS >= 1500 - 28, "FATAL: Cannot handle normal size IPv4/UDP packet");
                    _Static_assert(12 + CHUNK_SIZE * NUM_STEPS >= 65535, "WARNING: Cannot handle full size IPv4/UDP packet");
                    _Static_assert(12 + CHUNK_SIZE * (NUM_STEPS - 1) < 65535, "WARNING: Wasteful, reduce NUM_STEPS");
                    _Static_assert(12 == IP4_OFFSET(saddr), "FATAL: bad ip4 struct definition");

                    uint32_t buf[CHUNK_SIZE / 4] = {};  // must be zero initialized
                    uint32_t sum = htons(IPPROTO_UDP) + uh->len;  // *partial* pseudoheader checksum
//#pragma unroll
                    for (int i = NUM_STEPS - 1; i >= 0; --i) {  // vitally important we go backwards
                        int ofs = ETH_HLEN + IP4_OFFSET(saddr) + CHUNK_SIZE * i;  // includes rest of pseudoheader, assumes no ipv4 options
                        //int bytes = skb->len - ofs;
                        //int bytes = ETH_HLEN + ntohs(ip4->tot_len) - ofs;
                        //int bytes = ETH_HLEN + sizeof(*ip4) + udp_len - ofs;  <-- why does this fail?
                        int bytes = ETH_HLEN + sizeof(*ip4) + ntohs(uh->len) - ofs;
                        if (bytes <= 0) continue;
                        bpf_skb_load_bytes(skb, ofs, buf, bytes < CHUNK_SIZE ? bytes : CHUNK_SIZE);  // zero padded by virtue of going from the back
                        sum = bpf_csum_diff(NULL, 0, buf, CHUNK_SIZE, sum);
                    }

                    sum = (sum >> 16) + (sum & 0xFFFF);
                    sum = (sum >> 16) + (sum & 0xFFFF);
                    uint16_t sum16 = ~sum ?: 0xFFFF;
                    bpf_printf("nat46 udp csum=%016llX %04X", sum, sum16);
                    uh->check = sum16;  // bye bye to sanity of any csum offload skb state
                    TC_COUNT(UDP4_CSUM0);
                    // return TC_ACT_SHOT;
                };
                break;
            }

            case IPPROTO_ICMP: {
                // only needed if we reach > 4 bytes in
                if (data + ETH_HLEN + sizeof(*ip4) + sizeof(struct icmphdr) > data_end) { bpf_printf("nat46 short3:%d", data_end - data); TC_DROP(ICMP_OOB); };
                struct icmphdr* ih = (struct icmphdr*)(ip4 + 1);
                //bpf_printf("nat46 icmp4[%d/%d] id:%d", ih->type, ih->code, ntohs(ih->un.echo.id));
                int ln = ntohs(ip4->tot_len);
                //bpf_printf("nat46 icmp4 skb->len:%d da:%d tot_len:%d", skb->len, data_end - data, ln);
                //if (data + 98 > data_end) TC_DROP();
                uint64_t cs;
                //cs = bpf_csum_diff(NULL, 0, data + ETH_HLEN + 20, 64 /*98 - ETH_HLEN - 20*/, 0xFFFF);
                //cs = (cs >> 16) + (cs & 0xFFFF);
                //cs = (cs >> 16) + (cs & 0xFFFF);
                //bpf_printf("nat46 icmp4 %d csum:%04x [%04x]", 14 + ln, ntohs(ih->checksum), ntohs(cs));

                __u8 new_type;
                __u8 new_code = ih->code;
                switch (ih->type) {
                    // #define ICMP_ECHOREPLY      0   // Echo Reply
                    // #define ICMP_DEST_UNREACH   3   // Destination Unreachable
                    // #define ICMP_ECHO           8   // Echo Request
                    // #define ICMP_TIME_EXCEEDED  11  // Time Exceeded
                    // #define ICMP_PARAMETERPROB  12  // Parameter Problem

                    // #define ICMPV6_DEST_UNREACH 1
                    // #define ICMPV6_PKT_TOOBIG   2
                    // #define ICMPV6_TIME_EXCEED  3
                    // #define ICMPV6_PARAMPROB    4
                    // #define ICMPV6_ECHO_REQUEST 128
                    // #define ICMPV6_ECHO_REPLY   129

                    case ICMP_ECHO:          new_type = ICMPV6_ECHO_REQUEST; break;
                    case ICMP_ECHOREPLY:     new_type = ICMPV6_ECHO_REPLY;   break;
                    case ICMP_TIME_EXCEEDED: new_type = ICMPV6_TIME_EXCEED;  break;
                    case ICMP_DEST_UNREACH:  new_type = ICMPV6_DEST_UNREACH; break; // Should special case 'code' in { ICMP_UNREACH_PROTOCOL, ICMP_UNREACH_NEEDFRAG }
                    default: TC_DROP(ICMP_UNKNOWN);
                }
                //bpf_printf("nat46 s:%08X d:%08X", ntohl(ip4->saddr), ntohl(ip4->daddr));
                proto = IPPROTO_ICMPV6;
                cs = ih->checksum + 2 * 0xFFFFFFFFL + 3 * 0xFFFF + ih->type - new_type + (ih->code << 8) - (new_code << 8) - ip4->saddr - ip4->daddr;
                ih->type = new_type;
                ih->code = new_code;

                //bpf_printf("src:%04x dst:%04x cs:%08lx", ntohl(ip4->saddr), ntohl(ip4->daddr), cs);

                //cs = (cs >> 16) + (cs & 0xFFFF);
                //cs = (cs >> 16) + (cs & 0xFFFF);
                //ih->checksum = cs;

                //cs = bpf_csum_diff(NULL, 0, data + ETH_HLEN + 20 - 8, 64 + 8 /*98 - ETH_HLEN - 12*/, 0xFFFF);
                //cs = (cs >> 16) + (cs & 0xFFFF);
                //cs = (cs >> 16) + (cs & 0xFFFF);
                //if (cs != 0xFFFF) 
                //bpf_printf("updated: %04x [%04x]", ntohs(ih->checksum), ntohs(cs));

                // cs = ih->checksum + 0xFFFFL * 2;
                // ln is 84 -> 64 == 0x40, IPPROTO_ICMPV6 is 58 = 0x3a
                cs -= IPPROTO_ICMPV6 << 8;
                cs -= htons(ln - 20 + is_fragment * 5);// + 5); //+8);
                // cs can slightly exceed 32 bits here (0xFFFF + 2*0xFFFFFFFF + 3*0xFFFF + 0xFF = 0x2_0004_00f9)
                //         1FFFE is max which can be collapsed with 1 round  of cs = (cs >> 16) + (cs & 0xFFFF)
                //     1FFFFFFFE is max which can be collapsed with 2 rounds of cs = (cs >> 16) + (cs & 0xFFFF)
                // 1FFFFFFFFFFFE is max which can be collapsed with 3 rounds of cs = (cs >> 16) + (cs & 0xFFFF)
                cs = (cs >> 16) + (cs & 0xFFFF);
                cs = (cs >> 16) + (cs & 0xFFFF);
                cs = (cs >> 16) + cs; // final round doesn't need the mask, because:
                ih->checksum = cs; // assignment to 16-bit field discards all but bottom 16 bits

                //bpf_printf("updated2: %04x", ntohs(ih->checksum));
                break;
                //return TC_ACT_SHOT;
            }

            default:  // do not know how to handle anything else
                bpf_printf("nat46 proto: %d", proto);
                TC_DROP(UNKNOWN_PROTO);
        }
    }

    struct ipv6hdr ip6 = {
        .version = 6,                                       // __u8:4
        .priority = ip4->tos >> 4,                          // __u8:4
        .flow_lbl = {(ip4->tos & 0xF) << 4, 0, 0},          // __u8[3]
        .payload_len = htons(ntohs(ip4->tot_len) - 20 + is_fragment * 8),  // __be16
        .nexthdr = is_fragment ? IPPROTO_FRAGMENT : proto,  // __u8
        .hop_limit = ip4->ttl,                              // __u8
        .saddr = v->local6,                                 // struct in6_addr
        .daddr = v->pfx96,                                  // struct in6_addr
    };
    ip6.daddr.in6_u.u6_addr32[3] = ip4->daddr;

    // Calculate the IPv6 16-bit one's complement checksum of the IPv6 header.
    __wsum sum6 = 0;
    // We'll end up with a non-zero sum due to ip6.version == 6
    for (int i = 0; i < sizeof(ip6) / sizeof(__u16); ++i) sum6 += ((__u16*)&ip6)[i];

    struct frag_hdr fh = {
        .nexthdr = proto,                                          // __u8
        .reserved = 0,                                             // __u8
        .frag_off = htons((ntohs(ip4->frag_off) << 3) | (ntohs(ip4->frag_off & htons(IP_MF)) >> 13)),  // __be16
        .identification = htonl(ntohs(ip4->id)),                   // __be32
    };

    // Note that there is no L4 checksum update: we are relying on the checksum neutrality
    // of the ipv6 address chosen by netd's ClatdController.

    // Packet mutations begin - point of no return, but if this first modification fails
    // the packet is probably still pristine, so let clatd handle it.
    if (bpf_skb_change_proto(skb, htons(ETH_P_IPV6), 0)) TC_DROP(CHANGE_PROTO);

    // This takes care of updating the skb->csum field for a CHECKSUM_COMPLETE packet.
    //
    // In such a case, skb->csum is a 16-bit one's complement sum of the entire payload,
    // thus we need to subtract out the ipv4 header's sum, and add in the ipv6 header's sum.
    // However, we've already verified the ipv4 checksum is correct and thus 0.
    // Thus we only need to add the ipv6 header's sum.
    //
    // bpf_csum_update() always succeeds if the skb is CHECKSUM_COMPLETE and returns an error
    // (-ENOTSUPP) if it isn't.  So we just ignore the return code (see above for more details).
    bpf_csum_update(skb, sum6);

    if (is_fragment) {
        if (bpf_skb_adjust_room(skb, +(__s32)sizeof(struct frag_hdr), BPF_ADJ_ROOM_MAC, /*flags*/0)) {
            bpf_printf("nat46 frag fail");
            TC_DROP(ADJUST_ROOM);
        }
        //bpf_printf("nat46 frag ok");
    }

    // bpf_skb_change_proto() invalidates all pointers - reload them.
    data = (void*)(long)skb->data;
    data_end = (void*)(long)skb->data_end;

    // not clear this is checking the right thing, this should probably be checking the rawip/ether of the interface we're attached too
    // and or adding a header, etc   (also note oifIsEthernet is always true with current install script)
    if (v->oifIsEthernet) {
        // I cannot think of any valid way for this error condition to trigger, however I do
        // believe the explicit check is required to keep the in kernel ebpf verifier happy.
        if (data + ETH_HLEN + sizeof(ip6) > data_end) TC_DROP(ETHER_OOB);

        //if (((struct ethhdr*)data)->h_proto == htons(ETH_P_IP))
        ((struct ethhdr*)data)->h_proto = htons(ETH_P_IPV6);

        // Copy over the new ipv6 header without an ethernet header.
        *(struct ipv6hdr*)(data + ETH_HLEN) = ip6;

        if (is_fragment) {
            if (data + ETH_HLEN + sizeof(ip6) + sizeof(fh) > data_end) TC_DROP(ETHER_FRAG_OOB);
            *(struct frag_hdr*)(data + ETH_HLEN + sizeof(ip6)) = fh;
        }
    } else {
        // I cannot think of any valid way for this error condition to trigger, however I do
        // believe the explicit check is required to keep the in kernel ebpf verifier happy.
        if (data + sizeof(ip6) > data_end) TC_DROP(RAWIP_OOB);

        // Copy over the new ipv6 header without an ethernet header.
        *(struct ipv6hdr*)data = ip6;
        if (is_fragment) {
            if (data + sizeof(ip6) + sizeof(fh) > data_end) TC_DROP(RAWIP_FRAG_OOB);
            *(struct frag_hdr*)(data + sizeof(ip6)) = fh;
        }
    }

    // Count successfully translated packet
    __sync_fetch_and_add(&v->packets, 1);
    __sync_fetch_and_add(&v->bytes, skb->len - v->oifIsEthernet * ETH_HLEN);

    // Redirect to non v4-* interface.  Tcpdump only sees packet after this redirect.
    if (v->oif) {
        TC_COUNT(XLAT_REDIRECT);
        return bpf_redirect(v->oif, 0 /* this is effectively BPF_F_EGRESS */);
    }
    TC_COUNT(XLAT);
    return TC_ACT_PIPE;
}

LICENSE("GPL");
