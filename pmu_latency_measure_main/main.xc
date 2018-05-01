#include <xs1.h>
#include <xclib.h>
#include <print.h>
#include <platform.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <xscope.h>
#include "otp_board_info.h"
#include "ethernet.h"
#include "smi.h"
#include "ethernet_board_support.h"
#include "gptp.h"
#include "ethernet_conf.h"
#include "mac_custom_filter.h"
#include "debug_print.h"



#define UDP_HEADER_BYTES    8
#define IP_HEADER_BYTES     20
#define ETH_HEADER_BYTES    14

#define UDP_DEFAULT_PORT    4713

#define IP_DEFAULT_TTL      100
#define IP_VERSION          0x4
#define IP_IHL              0x5
#define IP_PROTOCOL_UDP     0x11

typedef struct eth_header {
    uint8_t dest[6];
    uint8_t source[6];
    uint16_t ethertype;
} ETH;

typedef struct ip_header {
    uint16_t info;
    uint16_t length;
    uint16_t id;
    uint16_t flags_frag;
    uint8_t ttl;
    uint8_t protocol;
    uint16_t checksum;
    uint32_t source;
    uint32_t dest;
    ETH eth;
} IP;

typedef struct udp_header {
    uint16_t source;
    uint16_t dest;
    uint16_t length;
    uint16_t checksum;
    IP ip;
} UDP;

// TODO reverse MAC encoding
// TODO check if broadcast works with ARP in use

uint8_t ETH_SOURCE[6] = { 0xa0, 0x56, 0x00, 0x97, 0x22, 0x00 }; // default; is overridden by local MAC address value at runtime
uint8_t ETH_SOURCE2[6] = { 0xa0, 0x56, 0x00, 0x97, 0x22, 0x00 }; // default; is overridden by local MAC address value at runtime
uint8_t ETH_DEST[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };  // set to PMU's MAC address, or leave as broadcast
//uint8_t ETH_DEST[6] = { 0x6d, 0x90, 0x4f, 0xc2, 0x50, 0x00 };  // set to PMU's MAC address, or leave as broadcast

uint8_t IP_SOURCE[4] = { 192, 168, 2, 19 }; // local IP address; set to approprate value for the network
uint8_t IP_DEST[4] = { 192, 168, 2, 111 };  // set to PMU's IP address, or leave as broadcast

// a simple memcpy implementation, that reverses endian-ness
void reversememcpy(unsigned char *dst, const unsigned char *src, unsigned int len) {
    size_t i;
    for (i = 0; i < len; ++i) {
        dst[len - 1 - i] = src[i];
    }
}

// copies bytes to network format (big-endian)
void netmemcpy(unsigned char *dst, const unsigned char *src, unsigned int len) {
    reversememcpy((unsigned char *)dst, (const unsigned char *)src, len);
}

int encodeETH(unsigned char* data, ETH* eth, const char *payload, int payload_length) {
    int size = 0;

    netmemcpy(&data[size], (const void*)eth->dest, 6);
    size += sizeof eth->dest;
    netmemcpy(&data[size], (const void*)eth->source, 6);
    size += sizeof eth->dest;
    netmemcpy(&data[size], (const void*)&eth->ethertype, sizeof eth->ethertype);
    size += sizeof eth->ethertype;

    return size;
}

uint16_t getIPChecksum(IP *ip) {
    uint32_t sum = ip->info + ip->length + ip->id + ip->flags_frag + ((ip->ttl << 8) | (ip->protocol)) + (ip->source & 0x0000FFFF) + ((ip->source & 0xFFFF0000) >> 16) + (ip->dest & 0x0000FFFF) + ((ip->dest & 0xFFFF0000) >> 16);
    uint8_t carry = (sum & 0x000F0000) >> 16;

    sum = sum + carry;

    return ~sum;
}

int encodeIP(unsigned char* data, IP* ip, const char *payload, int payload_length) {
    int size = 0;

    size += encodeETH(&data[size], &ip->eth, payload, payload_length);

    ip->length = IP_HEADER_BYTES + UDP_HEADER_BYTES + payload_length;
    ip->checksum = getIPChecksum(ip);

    netmemcpy(&data[size], (const void*)&ip->info, sizeof ip->info);
    size += sizeof ip->info;
    netmemcpy(&data[size], (const void*)&ip->length, sizeof ip->length);
    size += sizeof ip->length;
    netmemcpy(&data[size], (const void*)&ip->id, sizeof ip->id);
    size += sizeof ip->id;
    netmemcpy(&data[size], (const void*)&ip->flags_frag, sizeof ip->flags_frag);
    size += sizeof ip->flags_frag;
    netmemcpy(&data[size], (const void*)&ip->ttl, sizeof ip->ttl);
    size += sizeof ip->ttl;
    netmemcpy(&data[size], (const void*)&ip->protocol, sizeof ip->protocol);
    size += sizeof ip->protocol;
    netmemcpy(&data[size], (const void*)&ip->checksum, sizeof ip->checksum);
    size += sizeof ip->checksum;
    netmemcpy(&data[size], (const void*)&ip->source, sizeof ip->source);
    size += sizeof ip->source;
    netmemcpy(&data[size], (const void*)&ip->dest, sizeof ip->dest);
    size += sizeof ip->dest;

    return size;
}

int encode_UDP(unsigned char* data, UDP* udp, const char *payload, int payload_length) {
    int size = 0;

    size += encodeIP(&data[size], &udp->ip, payload, payload_length);

    udp->length = UDP_HEADER_BYTES + payload_length;
    udp->checksum = 0;

    netmemcpy(&data[size], (const void*)&udp->source, sizeof udp->source);
    size += sizeof udp->source;
    netmemcpy(&data[size], (const void*)&udp->dest, sizeof udp->dest);
    size += sizeof udp->dest;
    netmemcpy(&data[size], (const void*)&udp->length, sizeof udp->length);
    size += sizeof udp->length;
    netmemcpy(&data[size], (const void*)&udp->checksum, sizeof udp->checksum);
    size += sizeof udp->checksum;

    memcpy(&data[size], (const void*)payload, payload_length);
    size += payload_length;

    return size;
}


void init_existing_UDP(UDP *udp, uint8_t *ip, uint8_t *mac) {
    udp->source = UDP_DEFAULT_PORT;
    udp->dest = UDP_DEFAULT_PORT;

    udp->ip.info = ((IP_VERSION << 12) | (IP_IHL << 8)) & 0xFFFF;
    udp->ip.id = 0;
    udp->ip.flags_frag = 0;
    udp->ip.ttl = IP_DEFAULT_TTL;
    udp->ip.protocol = IP_PROTOCOL_UDP;

    if (ip == NULL) {
        netmemcpy((void *)&(udp->ip.source), IP_SOURCE, 4);
    }
    else {
        memcpy((void *)&(udp->ip.source), ip, 4);
    }
    netmemcpy((void *)&(udp->ip.dest), IP_DEST, 4);

    if (mac == NULL) {
        memcpy((void *)(udp->ip.eth.source), ETH_SOURCE, 6);
    }
    else {
        netmemcpy((void *)(udp->ip.eth.source), mac, 6);
    }
    memcpy((void *)(udp->ip.eth.dest), ETH_DEST, 6);
    udp->ip.eth.ethertype = 0x0800;
}



enum Message_Type { C37_118_Data, C37_118_CFG_1, C37_118_CFG_2, C37_118_CFG_3, C37_118_DATA_TRANSMISSION };
enum Command_Type { C37_118_DATA_OFF = 1, C37_118_DATA_ON = 2 };

UDP udp;
uint16_t IDCODE = 2;
unsigned int pmu_frame_buf[512 / 4];
//uint16_t remote_port = 4713;
//uint8_t ip[] = { 192, 168, 2, 126 };
//uint8_t mac_dest[] = { 0xce, 0x95, 0x21, 0x05, 0x01, 0x00 };
uint8_t buf_payload[512] = {0};

//     Compute CRC-CCITT. *buf is a pointer to the first character in the message;
//    len is the number of characters in the message (not counting the CRC on the end)
uint16_t ComputeCRC(unsigned char *buf, unsigned char len) {
    uint16_t crc = 0xFFFF;
    uint16_t temp;
    uint16_t quick;
    int i;

    for (i = 0; i < len; i++) {
        temp = (crc >> 8) ^ buf[i];
        crc <<= 8;
        quick = temp ^ (temp >> 4);
        crc ^= quick;
        quick <<= 5;
        crc ^= quick;
        quick <<= 7;
        crc ^= quick;
    }

    return crc;
}

uint16_t write_data_transmission_frame(unsigned char *buf, uint32_t SOC_recv, uint32_t FRACSEC, uint16_t transmission_state) {
    uint16_t len = 0;
    unsigned char *FRAMESIZE_ptr;
    uint16_t FRAMESIZE = 0;

    uint16_t SYNC = 0xAA41;  // command frame
    netmemcpy(&buf[len], (const void*) &SYNC, sizeof SYNC);
    len += sizeof SYNC;

    FRAMESIZE_ptr = &buf[len];  // remember FRAMESIZE location for later
    len += sizeof FRAMESIZE;

    netmemcpy(&buf[len], (const void*) &IDCODE, sizeof IDCODE);
    len += sizeof IDCODE;

    netmemcpy(&buf[len], (const void*)&SOC_recv, sizeof SOC_recv);
    len += sizeof SOC_recv;

    netmemcpy(&buf[len], (const void*) &FRACSEC, sizeof FRACSEC);
    len += sizeof FRACSEC;

    netmemcpy(&buf[len], (const void*) &transmission_state, sizeof transmission_state);
    len += sizeof transmission_state;

    FRAMESIZE = len + 2;    // includes CRC size
    netmemcpy(FRAMESIZE_ptr, (const void*) &FRAMESIZE, sizeof FRAMESIZE);

    uint16_t crc = ComputeCRC(buf, len);
    netmemcpy(&buf[len], (unsigned char *) &crc, sizeof crc);
    len += sizeof crc;

    return len;
};

uint16_t write_ethernet_frame_into_buf(unsigned char *buf, uint32_t SOC_recv, uint32_t FRACSEC, uint16_t transmission_state) {
    uint16_t len_out = 0;
    uint16_t len_payload = 0;

    len_payload = write_data_transmission_frame(buf_payload, SOC_recv, FRACSEC, transmission_state);

    len_out = encode_UDP(buf, &udp, (const char*)buf_payload, len_payload);

    return len_out;
};



on tile[0]: otp_ports_t otp_ports_tile_0 = OTP_PORTS_INITIALIZER;
//on tile[0]: otp_ports_t otp_ports_tile_0_2 = OTP_PORTS_INITIALIZER;
on tile[1]: otp_ports_t otp_ports_tile_1 = OTP_PORTS_INITIALIZER;
on tile[0]: port ptp_sync_port = XS1_PORT_4A;    // PTP sync port

smi_interface_t smi1 = ETHERNET_DEFAULT_SMI_INIT;
on tile[0]: smi_interface_t smi_triangle = {0, XS1_PORT_1M, XS1_PORT_1N};

// Circle slot
mii_interface_t mii1 = ETHERNET_DEFAULT_MII_INIT;

// Square slot
on tile[1]: mii_interface_t mii2 = {
  XS1_CLKBLK_3, //
  XS1_CLKBLK_4, //
  XS1_PORT_1B,  //RX_CLK
  XS1_PORT_4D,  //INT_N
  XS1_PORT_4A,  //RXD
  XS1_PORT_1C,  //RX_DV
  XS1_PORT_1G,  //TX_CLK
  XS1_PORT_1F,  //TX_EN
  XS1_PORT_4B   //TXD
};

// Triangle slot
on tile[0]: mii_interface_t mii_triangle2 = {
  XS1_CLKBLK_1, //
  XS1_CLKBLK_2, //
  XS1_PORT_1J,  //RX_CLK
  XS1_PORT_1P,  //INT_N
  XS1_PORT_4E,  //RXD
  XS1_PORT_1K,  //RX_DV
  XS1_PORT_1I,  //TX_CLK
  XS1_PORT_1L,  //TX_EN
  XS1_PORT_4F   //TXD
};

//#define PORT_ETH_RXCLK on tile[1]: XS1_PORT_1B
//#define PORT_ETH_ERR on tile[1]: XS1_PORT_4D
//#define PORT_ETH_RXD on tile[1]: XS1_PORT_4A
//#define PORT_ETH_RXDV on tile[1]: XS1_PORT_1C
//#define PORT_ETH_TXCLK on tile[1]: XS1_PORT_1G
//#define PORT_ETH_TXEN on tile[1]: XS1_PORT_1F
//#define PORT_ETH_TXD on tile[1]: XS1_PORT_4B
//
//#define PORT_ETH_MDIOC on tile[1]: XS1_PORT_4C
//#define PORT_ETH_MDIOFAKE on tile[1]: XS1_PORT_8A


//#define PORT_ETH_RXCLK on tile[0]: XS1_PORT_1J
//#define PORT_ETH_ERR on tile[0]: XS1_PORT_1P
//#define PORT_ETH_RXD on tile[0]: XS1_PORT_4E
//#define PORT_ETH_RXDV on tile[0]: XS1_PORT_1K
//#define PORT_ETH_TXCLK on tile[0]: XS1_PORT_1I
//#define PORT_ETH_TXEN on tile[0]: XS1_PORT_1L
//#define PORT_ETH_TXD on tile[0]: XS1_PORT_4F

//#define PORT_ETH_MDIO on tile[0]: XS1_PORT_1M
//#define PORT_ETH_MDC on tile[0]: XS1_PORT_1N
//#define PORT_ETH_INT on tile[0]: XS1_PORT_1O

#define USE_TRIANGLE_PORT               1
#define SV_LATENCY                      0
#define SEND_PMU_GET_CONFIG_COMMAND     1
#define PMU_REQUIRES_ARP                1
#define CIRCLE_PORT                     0
#define SQUARE_PORT                     1
#define TRIANGLE_PORT                   0

#if USE_TRIANGLE_PORT == 1
#define PMU_PORT                        TRIANGLE_PORT
#else
#define PMU_PORT                        SQUARE_PORT
#endif

#define MAX_ARP_MESG_LENGTH             128
#define MAX_PMU_REPORTS                 7000
#if SV_LATENCY == 1
    #define MAX_PMU_REPORT_MESG_LENGTH  900
#else
    #define MAX_PMU_REPORT_MESG_LENGTH  128
#endif
#define PTP_IO_1PPS_ON                  0
#define PTP_IO_1PPS_OFF                 1

enum PMU_Latency_Test_State {
    IDLE = 0,
    SENT_START_TRANSMISSION,
    FINISHED_RECEIVING_REPORTS
};

typedef struct _PMU_latency_record {
    enum PMU_Latency_Test_State state;
    unsigned int start_transmission_sent_time;
//    unsigned int report_receive_time[MAX_PMU_REPORTS];
//    ptp_timestamp report_receive_time_ptp[MAX_PMU_REPORTS];
//    unsigned int report_timestamp[MAX_PMU_REPORTS];
//    unsigned int diff_microseconds[MAX_PMU_REPORTS];
//    unsigned int FRACSEC[MAX_PMU_REPORTS];
    unsigned int next_report_index;
    unsigned int num_reports;
    unsigned int max_reporting_latency;
} PMU_Latency_Record;

ptp_timestamp report_receive_time_ptp;
ptp_timestamp ptp_ts;
ptp_time_info ptp_info;
PMU_Latency_Record pmu_latency_record = {0};
unsigned int ARP_buf[MAX_ARP_MESG_LENGTH / 4];
unsigned int pmu_report_buf[MAX_PMU_REPORT_MESG_LENGTH / 4];
unsigned int pmu_report_len = 0;
unsigned int pmu_report_rx_ts = 0;
unsigned int pmu_report_port = 0;
unsigned int LEAP_SECONDS = 37;
unsigned int print_latency_count = 0;
int tile_timer_offset = 0;


void update_reporting_latency_results() {
    pmu_latency_record.max_reporting_latency = 0;
//    int i = 0;
    unsigned long long accumulator = 0;

//    for (i = 0; i < MAX_PMU_REPORTS; i++) {
//        accumulator += pmu_latency_record.diff_microseconds[i];
//        if (pmu_latency_record.diff_microseconds[i] > pmu_latency_record.max_reporting_latency) {
//            pmu_latency_record.max_reporting_latency = pmu_latency_record.diff_microseconds[i];
//        }
//    }

    debug_printf("max_reporting_latency: %d microseconds, mean: %d microseconds\n", pmu_latency_record.max_reporting_latency, accumulator / MAX_PMU_REPORTS);
}

int ARP_write(unsigned char ARP_sender_MAC_address[6], unsigned int ARP_sender_IP_address) {
    unsigned char *frame = (unsigned char *) ARP_buf;
    int len = 0;

    netmemcpy(&frame[len], ARP_sender_MAC_address, sizeof(ARP_sender_MAC_address));
//    memcpy(&frame[len], ETH_DEST, sizeof(ETH_DEST));
    len += sizeof(ARP_sender_MAC_address);
    netmemcpy(&frame[len], udp.ip.eth.source, sizeof(udp.ip.eth.source));
    len += sizeof(udp.ip.eth.source);

    unsigned short etype = 0x0806;
    netmemcpy(&frame[len], (const unsigned char *) &etype, sizeof(etype));
    len += sizeof(etype);

    unsigned short hw_type = 0x0001;
    netmemcpy(&frame[len], (const unsigned char *) &hw_type, sizeof(hw_type));
    len += sizeof(hw_type);
    unsigned short protocol_type = 0x0800;
    netmemcpy(&frame[len], (const unsigned char *) &protocol_type, sizeof(protocol_type));
    len += sizeof(protocol_type);

    unsigned char hw_size = 0x06;
    netmemcpy(&frame[len], (const unsigned char *) &hw_size, sizeof(hw_size));
    len += sizeof(hw_size);
    unsigned char protocol_size = 0x04;
    netmemcpy(&frame[len], (const unsigned char *) &protocol_size, sizeof(protocol_size));
    len += sizeof(protocol_size);

    unsigned short response = 0x0002;
    netmemcpy(&frame[len], (const unsigned char *) &response, sizeof(response));
    len += sizeof(response);

    netmemcpy(&frame[len], udp.ip.eth.source, sizeof(udp.ip.eth.source));
    len += sizeof(udp.ip.eth.source);
    netmemcpy(&frame[len], (const unsigned char *) &udp.ip.source, sizeof(udp.ip.source));
    len += sizeof(udp.ip.source);

    netmemcpy(&frame[len], ARP_sender_MAC_address, sizeof(ARP_sender_MAC_address));
    len += sizeof(ARP_sender_MAC_address);
    netmemcpy(&frame[len], (const unsigned char *) &ARP_sender_IP_address, sizeof(ARP_sender_IP_address));
    len += sizeof(ARP_sender_IP_address);

    // add padding for min frame size
    if (len < 60) {
        len = 60;
    }

    return len;
}

void print_bytes(unsigned int frame_buf[], unsigned int len) {
    unsigned char *frame = (unsigned char *) frame_buf;

    for (int b = 0; b < len; b++) {
        if (frame[b] < 16) {
            debug_printf(" %x ", frame[b]);
        }
        else {
            debug_printf("%x ", frame[b]);
        }

        if ((b + 1) % 8 == 0) {
            debug_printf("  ");
        }
        if ((b + 1) % 16 == 0) {
            debug_printf("\n");
        }
    }
    debug_printf("\n");
}

#pragma select handler
void delay_recv_and_process_packet(chanend c_rx, chanend c_tx, chanend ptp_link) {
    safe_mac_rx_timed(c_rx,
            (pmu_report_buf, unsigned char[]),
            pmu_report_len,
            pmu_report_rx_ts,
            pmu_report_port,
            MAX_PMU_REPORT_MESG_LENGTH);

    xscope_int(INTERFACE_NUM, pmu_report_port);

//    debug_printf("frame on port: %d\n", pmu_report_port);

    if (pmu_report_port == PMU_PORT) {
        unsigned char *frame = (unsigned char *) pmu_report_buf;
        unsigned short etype = (unsigned short) pmu_report_buf[3];
        int qhdr = (etype == 0x0081);
        if (qhdr) {
          // has a 802.1q tag - read etype from next word
          etype = (unsigned short) pmu_report_buf[4];
        }
//        debug_printf("etype (PMU_PORT): %x\n", etype);

        switch (etype) {

#if SV_LATENCY == 1
        case 0xba88:
//            debug_printf("SV etype (PMU_PORT): %x\n", etype);
            unsigned short SV_sample1_smpCnt = 0;
            unsigned short SV_sample1_SOC_h = 0;
            unsigned short SV_sample1_SOC_l = 0;
            unsigned int SOC = 0;

            // extract first sample data
            netmemcpy((unsigned char *) &SV_sample1_smpCnt, &frame[53], sizeof(SV_sample1_smpCnt));
            netmemcpy((unsigned char *) &SV_sample1_SOC_l, &frame[72], 2);
            netmemcpy((unsigned char *) &SV_sample1_SOC_h, &frame[72 + 8], 2);
            SOC = ((unsigned int) SV_sample1_SOC_l) + (((unsigned int) SV_sample1_SOC_h) << 16);

//            if (SV_sample1_smpCnt == 0 || SV_sample1_smpCnt == 12792) {
////                debug_printf("SV_sample1_SOC_l: %x, SV_sample1_SOC_h: %x, SOC: %x\n", SV_sample1_SOC_l, SV_sample1_SOC_h, SV_sample1_SOC);
//                debug_printf("SV SOC: %d, smpCnt: %d\n", SV_sample1_SOC, SV_sample1_smpCnt);
//            }

            unsigned int FRACSEC = ((10000 * SV_sample1_smpCnt) / 128) - 50;    // convert to integer us; adjust RTDS rack 2 delay
//            debug_printf("SV SOC: %d, FRACSEC: %d\n", SOC, FRACSEC);

//            debug_printf("PTP SOC: %d, FRACSEC: %d\n", ptp_info.ptp_ts.seconds[0], ptp_info.ptp_ts.nanoseconds);


            if (SV_sample1_smpCnt == 0) {
                ptp_get_time_info(ptp_link, ptp_info);
            }

            if (ptp_info.ptp_ts.seconds[0] < 10000000) {
                return;
            }

            local_timestamp_to_ptp(report_receive_time_ptp, pmu_report_rx_ts, ptp_info);

            int diff_microseconds = 0;
            int diff_s = (report_receive_time_ptp.seconds[0] - LEAP_SECONDS) - SOC;
            int diff_ns = report_receive_time_ptp.nanoseconds - (FRACSEC * 1000) - (tile_timer_offset * 10);

            if (diff_s == 0) {
                diff_microseconds = diff_ns / 1000;
            }
            else if (diff_s == 1) {
                diff_microseconds = (1000000000 + diff_ns) / 1000;
            }

//            pmu_latency_record.diff_microseconds[pmu_latency_record.next_report_index] = diff_microseconds;
//            pmu_latency_record.FRACSEC[pmu_latency_record.next_report_index] = FRACSEC;

//            debug_printf("diff: %d, %d\n", diff_s, diff_ns);
//            debug_printf("%d\n", diff_microseconds);

            if (diff_microseconds > 0 && print_latency_count <= MAX_PMU_REPORTS) {
                debug_printf("%d\n", diff_microseconds);
                print_latency_count++;
            }

            xscope_int(REPORTING_LATENCY, diff_microseconds);
            xscope_int(MAX_REPORTING_LATENCY, pmu_latency_record.max_reporting_latency);

            pmu_latency_record.next_report_index++;
            if (pmu_latency_record.next_report_index >= MAX_PMU_REPORTS) {
                pmu_latency_record.next_report_index = 0;
//                print_latency_count = 0;
//                update_reporting_latency_results();
                pmu_latency_record.state = IDLE;
            }

            ptp_get_time_info(ptp_link, ptp_info);
            break;
#endif
#if PMU_REQUIRES_ARP == 1
        case 0x0608:
                // ARP
                unsigned short ARP_operation = 0;
                unsigned char ARP_sender_MAC_address[6];
                unsigned int ARP_sender_IP_address = 0;
                unsigned int ARP_target_IP_address = 0;
                unsigned int ARP_local_IP_address = 0;

                netmemcpy((unsigned char *) &ARP_operation, &frame[20], sizeof(ARP_operation));
                netmemcpy((unsigned char *) &ARP_sender_MAC_address, &frame[22], sizeof(ARP_sender_MAC_address));
                netmemcpy((unsigned char *) &ARP_sender_IP_address, &frame[28], sizeof(ARP_sender_IP_address));
                netmemcpy((unsigned char *) &ARP_target_IP_address, &frame[38], sizeof(ARP_target_IP_address));
                netmemcpy((unsigned char *) &ARP_local_IP_address, (unsigned char *) &IP_SOURCE[0], sizeof(ARP_target_IP_address));

    //            debug_printf("ARP: %d, %x, %x, %x, %x %x %x %x\n", ARP_operation, ARP_sender_IP_address, ARP_target_IP_address, ARP_local_IP_address, IP_SOURCE[0], IP_SOURCE[1], IP_SOURCE[2], IP_SOURCE[3]);

                if (ARP_operation == 0x0001 && ARP_local_IP_address == ARP_target_IP_address) {

                    debug_printf("ARP send\n");
                    int len = ARP_write(ARP_sender_MAC_address, ARP_sender_IP_address);
    //                debug_printf("len: %d\n", len);

    //                print_bytes(ARP_buf, len);

                    if (len > 0) {
//                        mac_tx(c_tx, ARP_buf, len, PMU_PORT);
                    }
                }
                break;
#endif

#if SV_LATENCY != 1
        case 0x0008:
                // TODO check ethertype for VLAN
                if (frame[42] != 0xaa || frame[43] != 0x01) {
                    // not Synchrophasor
                    return;
                }

//                debug_printf("PMU packet\n");

                pmu_latency_record.state = SENT_START_TRANSMISSION;

                unsigned int SOC = 0;
                unsigned int FRACSEC = 0;
    //            ptp_timestamp report_receive_time_ptp;

                netmemcpy((unsigned char *) &SOC, &frame[48], 4);
                netmemcpy((unsigned char *) &FRACSEC, &frame[52], 4);

                FRACSEC = FRACSEC & 0x00FFFFFF; // ignore time quality flags

//                              debug_printf("SOC: %d, ", SOC);
//                              debug_printf("FRACSEC: %d\n", FRACSEC);
    //            pmu_latency_record.report_receive_time[pmu_latency_record.next_report_index] = pmu_report_rx_ts;
                //            local_timestamp_to_ptp(pmu_latency_record.report_receive_time_ptp[pmu_latency_record.next_report_index], pmu_latency_record.report_receive_time[pmu_latency_record.next_report_index], ptp_info);
                local_timestamp_to_ptp(report_receive_time_ptp, pmu_report_rx_ts, ptp_info);

    //            debug_printf("ts: %d s, %d ns (%d, %d)\n", report_receive_time_ptp.seconds[0] - LEAP_SECONDS, report_receive_time_ptp.nanoseconds, ptp_info.ptp_adjust, ptp_info.inv_ptp_adjust);

                //              debug_printf("ts: %d, s[0]: %d, s[1]: %d, ns: %d\n",
                //                      pmu_latency_record.report_receive_time[pmu_latency_record.next_report_index],
                //                      pmu_latency_record.report_receive_time_ptp[pmu_latency_record.next_report_index].seconds[0] - LEAP_SECONDS,
                //                      pmu_latency_record.report_receive_time_ptp[pmu_latency_record.next_report_index].seconds[1],
                //                      pmu_latency_record.report_receive_time_ptp[pmu_latency_record.next_report_index].nanoseconds);

                int diff_microseconds = 0;
                int diff_s = (report_receive_time_ptp.seconds[0] - LEAP_SECONDS) - SOC;
                int diff_ns = report_receive_time_ptp.nanoseconds - (FRACSEC * 1000) - (tile_timer_offset * 10);

                if (diff_s == 0) {
                    diff_microseconds = diff_ns / 1000;
                }
                else if (diff_s == 1) {
                    diff_microseconds = (1000000000 + diff_ns) / 1000;
                }

    //            pmu_latency_record.diff_microseconds[pmu_latency_record.next_report_index] = diff_microseconds;
    //            pmu_latency_record.FRACSEC[pmu_latency_record.next_report_index] = FRACSEC;

                debug_printf("diff: %d, %d\n", diff_s, diff_ns);

                if (diff_microseconds > 0 && print_latency_count <= MAX_PMU_REPORTS) {
                    debug_printf("%d\n", diff_microseconds);
                    print_latency_count++;
                }

                xscope_int(REPORTING_LATENCY, diff_microseconds);
                xscope_int(MAX_REPORTING_LATENCY, pmu_latency_record.max_reporting_latency);

                pmu_latency_record.next_report_index++;
                if (pmu_latency_record.next_report_index >= MAX_PMU_REPORTS) {
                    pmu_latency_record.next_report_index = 0;
    //                print_latency_count = 0;
    //                update_reporting_latency_results();
                    pmu_latency_record.state = IDLE;
                }

                ptp_get_time_info(ptp_link, ptp_info);

            break;
#endif
        default:
            break;
        }
    }
}


void latency_watcher(chanend c_rx, chanend c_tx, chanend ptp_link) {
    timer periodic_timer;
    unsigned int periodic_timeout;
    unsigned int time = 0;
    unsigned int len = 0;
    ptp_timestamp local_time;
    unsigned int start = 0;

    // get inter-tile timer offset for comparing Ethernet Rx times to PTP time
    mac_get_tile_timer_offset(c_rx, tile_timer_offset);
//    debug_printf("latency_watcher() tile_timer_offset: %d ticks\n", tile_timer_offset);

//    char mac_address_tile_0[6];
    //    init_existing_UDP(&udp, NULL, mac_address_tile_0);
//    uint8_t ETH_SOURCE3[6] = { 0xa0, 0x56, 0x00, 0x97, 0x22, 0x00 };
    uint8_t ETH_SOURCE3[6] = { 0x00, 0x22, 0x97, 0x00, 0x56, 0xa0 };
    init_existing_UDP(&udp, NULL, ETH_SOURCE3);

//    mac_set_custom_filter(c_rx, MAC_FILTER_IP);
//    mac_set_custom_filter(c_rx, MAC_FILTER_ARP);
//    mac_set_custom_filter(c_rx, MAC_FILTER_SV);
    mac_set_custom_filter(c_rx, 0xFFFFFFFF);

    periodic_timer :> periodic_timeout;
    periodic_timeout += 1000000000;

    ptp_get_time_info(ptp_link, ptp_info);        // TODO need to call this periodically?   TODO can share this instance?

    while (1) {
        [[ordered]]
         select {
         case delay_recv_and_process_packet(c_rx, c_tx, ptp_link):
             break;
#if SV_LATENCY != 1
         case periodic_timer when timerafter(periodic_timeout) :> time:
             // wait for PTP task to sync
             if (start < 3) {
                 debug_printf("timeout\n");
                 periodic_timeout += 1000000000;
                 start++;
                 break;
             }
             periodic_timeout += 500000000;

             ptp_get_time_info(ptp_link, ptp_info);
             local_timestamp_to_ptp(local_time, time, ptp_info);

             if (pmu_latency_record.state == IDLE) {
                 debug_printf("time: %d.%d\n", local_time.seconds[0], local_time.nanoseconds);

#if SEND_PMU_GET_CONFIG_COMMAND == 1
                 len = write_ethernet_frame_into_buf((unsigned char *) pmu_frame_buf, local_time.seconds[0], local_time.nanoseconds / 1000, 5);
                 pmu_latency_record.next_report_index = 0;
                 if (len > 0) {
                     mac_tx_timed(c_tx, pmu_frame_buf, len, pmu_latency_record.start_transmission_sent_time, PMU_PORT);
                 }
#endif

                 len = write_ethernet_frame_into_buf((unsigned char *) pmu_frame_buf, local_time.seconds[0], local_time.nanoseconds / 1000, 2);
                 pmu_latency_record.next_report_index = 0;
                 if (len > 0) {
                     mac_tx_timed(c_tx, pmu_frame_buf, len, pmu_latency_record.start_transmission_sent_time, PMU_PORT);
                 }
             }
             break;
#endif
         default:
             break;
        }
    }
}


void ptp_one_pps(chanend ptp_link, port test_clock_port) {
    int x = 0;
    timer tmr;
    unsigned int t, t2;
    ptp_timestamp ptp_ts;
    ptp_time_info ptp_info_1pps;

    ptp_get_time_info(ptp_link, ptp_info_1pps);

    while (1) {
        [[ordered]]
        select {
            case tmr when timerafter(t) :> t2:
                test_clock_port <: x;

                local_timestamp_to_ptp(ptp_ts, t2, ptp_info_1pps);

                if (x == PTP_IO_1PPS_ON) {
                    ptp_ts.seconds[0] += 1;
                    ptp_ts.nanoseconds = 0;
                    x = PTP_IO_1PPS_OFF;
                }
                else {
                    ptp_ts.nanoseconds = 10000000;
                    x = PTP_IO_1PPS_ON;

                    ptp_request_time_info(ptp_link);
                }

                t = ptp_timestamp_to_local(ptp_ts, ptp_info_1pps);
//                if (x == PTP_IO_1PPS_OFF) {
//                    t = t - 38;
//                }

        //        if (x == PTP_IO_1PPS_OFF) {
        //            debug_printf("%u, %u, %u, %u; %u\n", t, t2, ptp_info.ptp_ts.seconds[0], ptp_info.ptp_ts.nanoseconds, ptp_info.local_ts);
        //        }

                break;
             case ptp_get_requested_time_info(ptp_link, ptp_info_1pps):
                 break;
        }
    }
}


int main() {
    chan c_mac_rx[2], c_mac_tx[2];
    chan c_mac_rx2[1], c_mac_tx2[1];
    chan c_ptp[2];

    par {
        on tile[1]: {
            char mac_address[6];
            otp_board_info_get_mac(otp_ports_tile_1, 0, mac_address);
            smi_init(smi1);
            eth_phy_config(1, smi1);
            ethernet_server_full_two_port(mii1,
                    mii2,
                    smi1,
                    null,
                    mac_address,
                    c_mac_rx, 2,
                    c_mac_tx, 2);
        }

        on tile[0]: {
//            char mac_address_tile_0[6] = {0xa0, 0x56, 0x00, 0x97, 0x22, 0x00};
//            otp_board_info_get_mac(otp_ports_tile_0, 0, mac_address_tile_0);
//            otp_board_info_get_mac(otp_ports_tile_0_2, 0, mac_address_tile_0);
            smi_init(smi_triangle);
            eth_phy_config(1, smi_triangle);
            ethernet_server_full(mii_triangle2,
                    smi_triangle,
                    ETH_SOURCE2,
                    c_mac_rx2, 1,
                    c_mac_tx2, 1);
        }

        on tile[0]: ptp_server(c_mac_rx[0],
                                  c_mac_tx[0],
                                  c_ptp,
                                  2,
                                  PTP_SLAVE_ONLY);

        on tile[0]: latency_watcher(c_mac_rx2[0], c_mac_tx2[0], c_ptp[0]);

        on tile[0]: ptp_one_pps(c_ptp[1], ptp_sync_port);
    }

  return 0;
}

