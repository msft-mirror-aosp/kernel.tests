// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2025, Google
// Author: Maciej Żenczykowski

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <netinet/ip.h>
#include <netinet/udp.h>

#define defer(f) __attribute__((cleanup(f)))

void fd_closer(const int * fd) {
    if (*fd >= 0) close(*fd);
}

void ptr_u8_freer(uint8_t * const * mem) {
    free(*mem);
}

const int MAX_PAYLOAD_SIZE = 65535 - 20 - 8;

uint16_t udp_csum(uint16_t *ptr, unsigned nbytes) {
    uint32_t sum = 0;

    while (nbytes >= 2) {
        sum += *ptr++;
        nbytes -= 2;
    }
    if (nbytes) {
        uint16_t oddbyte = 0;
        *((uint8_t *)&oddbyte) = *(uint8_t *)ptr;
        sum += oddbyte;
    }

    sum = (sum >> 16) + (sum & 0xFFFF);
    sum = (sum >> 16) + (sum & 0xFFFF);
    uint16_t csum = ~sum;
    return csum ?: 0xFFFF;
}

int main(const int argc, const char * const argv[]) {
    if (argc != 4) {
        fprintf(stderr, "Usage: %s <destination_ipv4> <destination_port> <payload_size>\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    const char * const dest_ip_str = argv[1];
    const int dest_port = atoi(argv[2]);
    const int payload_size = atoi(argv[3]);

    if (payload_size < 0 || payload_size > MAX_PAYLOAD_SIZE) {
        fprintf(stderr, "Payload size must be between 0 and %d\n", MAX_PAYLOAD_SIZE);
        exit(EXIT_FAILURE);
    }

    // Create a standard UDP socket
    defer(fd_closer)
    const int sockfd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (sockfd < 0) {
        perror("socket() failed");
        exit(EXIT_FAILURE);
    }

    // Prepare destination address
    struct sockaddr_in dest_addr = {
        .sin_family = AF_INET,
        .sin_port = htons(dest_port),
    };
    if (inet_pton(AF_INET, dest_ip_str, &dest_addr.sin_addr) <= 0) {
        perror("invalid destination IP address");
        exit(EXIT_FAILURE);
    }

    if (connect(sockfd, &dest_addr, sizeof(dest_addr)) != 0) {
        perror("connect() failed");
        exit(EXIT_FAILURE);
    }

    // Get the local source IP address for checksum calculation
    struct sockaddr_in source_addr = {};
    socklen_t addrlen = sizeof(source_addr);
    if (getsockname(sockfd, (struct sockaddr *)&source_addr, &addrlen) != 0) {
        perror("getsockname() failed");
        exit(EXIT_FAILURE);
    }

    // --- UDP Checksum Calculation ---
    struct pseudo_header {
        uint32_t saddr;
        uint32_t daddr;
        uint8_t zero;
        uint8_t protocol;
        uint16_t udp_length;
    };
    // 12 bytes (which is less than 20 bytes of ipv4 header) + 8 + max 65507 = 65527, so no overflow

    uint16_t pseudogram_size = sizeof(struct pseudo_header) + sizeof(struct udphdr) + payload_size;
    defer(ptr_u8_freer)
    uint8_t *pseudogram = calloc(pseudogram_size, 1);
    if (!pseudogram) {
        perror("calloc() failed");
        exit(EXIT_FAILURE);
    }

    // Create the pseudo-header
    struct pseudo_header* psh = (struct pseudo_header*)pseudogram;
    *psh = (struct pseudo_header){
        .saddr = source_addr.sin_addr.s_addr,
        .daddr = dest_addr.sin_addr.s_addr,
        .protocol = IPPROTO_UDP,
        .udp_length = htons(sizeof(struct udphdr) + payload_size),
    };

    struct udphdr* uh = (struct udphdr*)(psh + 1);
    *uh = (struct udphdr){
        .source = source_addr.sin_port,
        .dest = htons(dest_port),
        .len = psh->udp_length,
    };

    // Create a random payload
    srand(time(NULL));
    uint8_t *payload = (uint8_t*)(uh + 1);
    for (int i = 0; i < payload_size; ++i) payload[i] = rand();  //0

    // Calculate the checksum
    uint16_t correct_checksum = udp_csum((uint16_t *)pseudogram, pseudogram_size);

    // --- Send the packet with a zero checksum ---
    // The kernel will ignore the checksum if SO_NO_CHECK is set, but we still calculate and print it.
    int disable_checksum = 1;
//again:
    if (setsockopt(sockfd, SOL_SOCKET, SO_NO_CHECK, &disable_checksum, sizeof(disable_checksum)) < 0) {
        perror("setsockopt(SO_NO_CHECK) failed");
        exit(EXIT_FAILURE);
    }

    ssize_t sent_bytes = sendto(sockfd, payload, payload_size, 0, (struct sockaddr *)&dest_addr, sizeof(dest_addr));
    if (sent_bytes < 0) {
        perror("sendto() failed");
        exit(EXIT_FAILURE);
    }
    if (sent_bytes != payload_size) {
        fprintf(stderr, "sendto() failed [%zd != %d]", sent_bytes, payload_size);
        exit(EXIT_FAILURE);
    }

    for (int i = 0; i < pseudogram_size; ++i) {
        if (i == 8) printf("[ ");
        if (i == 12) printf("] ");
        if (i == 20) printf("| ");
        printf("%02x ", pseudogram[i]);
    }
    printf("\n");

    printf("Sent a %zd-byte UDP packet to %s:%d (%08X:%d -> %08X:%d) with no checksum (expected 0x%04X)\n",
           sent_bytes, dest_ip_str, dest_port,
           ntohl(source_addr.sin_addr.s_addr), ntohs(source_addr.sin_port),
           ntohl(dest_addr.sin_addr.s_addr), ntohs(dest_addr.sin_port),
           correct_checksum);
//  if (disable_checksum) { disable_checksum = 0; goto again; }
    return 0;
}
