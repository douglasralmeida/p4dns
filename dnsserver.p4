/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

#define MAX_DNSNAMELENGTH 63

const bit<16> TYPE_IPV4 = 0x800;
const bit<8> TYPE_UDP = 17;

const bit<16> DNS_CLASS_INTERNET = 1;
const bit<16> DNS_PORT = 53;

const bit<4> DNS_RESP_NOERROR = 0;
const bit<4> DNS_RESP_NAMEERROR = 3;

const bit<1> DNS_TYPE_QUERY = 0;
const bit<1> DNS_TYPE_RESPONSE = 1;

const bit<16> DNS_RR_ADDRESS = 1;

const bit<2> DNS_COMPRESSION = 3;

/*************************************************************************
************************** H E A D E R S *********************************
*************************************************************************/
typedef bit<9>    port_t;
typedef bit<512>  string_t;
typedef bit<48>   macAddr_t;
typedef bit<32>   ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> totalLen;
    bit<16> checksum;
}

header dns_t {
    bit<16> id;
    bit<1>  qr;
    bit<4>  opCode;
    bit<1>  authAnswer;
    bit<1>  trunc;
    bit<1>  recurDesired;
    bit<1>  recurAvail;
    bit<3>  reserved;
    bit<4>  respCode;
    bit<16> qdCount;
    bit<16> anCount;
    bit<16> nsCount;
    bit<16> arCount;
}

header dns_querylen_t {
    bit<8>   totalLen;
}

/*
    Include dns query text header for
    all text size possibilites
*/
#include "inc/declaration.p4"

header dnsqueryopt_t {
    bit<16>  type;
    bit<16>  class;
}

header dnsanswer_t {
    bit<2>    compression;
    bit<14>   offset;
    bit<16>   type;
    bit<16>   class;
    bit<32>   ttl;
    bit<16>   rdLength;
    ip4Addr_t rdData;
}

struct metadata_t {
    bit<1> is_dns;
    bit<1> is_query;
    bit<8> querylen;
}

struct headers {
    ethernet_t                ethernet;
    ipv4_t                    ipv4;
    udp_t                     udp;
    dns_t                     dns;
    dns_querylen_t            dns_querylen;
    dnstext_t                 dns_querytext;
    dnsqueryopt_t             dns_queryopt;
    dnsanswer_t               dns_answer;
}

/*************************************************************************
*************************** P A R S E R **********************************
*************************************************************************/

parser DnsParser(packet_in packet,
                out headers hdr,
                inout metadata_t meta,
                inout standard_metadata_t standard_metadata) {

    bit<1> aa;
    bit<2> ab;

    /* start parsing */
    state start {
        meta.is_dns = 0;
        meta.is_query = 0;
        meta.querylen = 0;

        /* parse ethernet packet */
        transition parse_ethernet;
    }

    /* start parsing ethernet packet */
    state parse_ethernet {
        /* extract ethernet packet from input packet */
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            /* parse IP packet */
            TYPE_IPV4: parse_ipv4;
            default: accept;
       }
    }

    /* start parsing IP packet */
    state parse_ipv4 {
        /* extract IP packet from ethernet packet */
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            /* parse UDP packet */
            TYPE_UDP: parse_udp;
            default: accept;
        }
    }

    /* start parsing UDP packet */
    state parse_udp {
        /* extract DNS packet from UDP packet */
        packet.extract(hdr.udp);
        transition select(hdr.udp.dstPort == 53) {
            /* parse DNS packet */
            true: parse_dns;
            false: accept;
        }
    }

    /* start parsing DNS packet */
    state parse_dns {
        /* extract DNS data in DNS packet */
        packet.extract(hdr.dns);
        meta.is_dns = 1;
        transition select(hdr.dns.qr) {
            /* parse DNS question or response */
            DNS_TYPE_QUERY: parse_dnsquery;
            DNS_TYPE_RESPONSE: parse_dnsanswer;
            default: accept;
        }
    }

    /* start parsing DNS query text */
    #include "inc/parsing.p4"

    /* start parsing DNS query options */
    state parse_dnsqueryoptions {
        /* extract DNS query options in DNS packet */
        packet.extract(hdr.dns_queryopt);
        meta.is_query = 1;

        transition accept;
    }

    /* start parsing DNS answer */
    state parse_dnsanswer {
        /* extract DNS answer in DNS packet */
        //packet.extract(hdr.dns_querylen);
        //packet.extract(hdr.dns_queryopt);
        //packet.extract(hdr.dns_answer);
        transition accept;
    }
}

/*************************************************************************
************** C H E C K S U M     V E R I F I C A T I O N ***************
*************************************************************************/

control DnsVerifyChecksum(inout headers hdr, inout metadata_t meta) {
    apply {

    }
}

/*************************************************************************
****************** I N G R E S S    P R O C E S S I N G ******************
*************************************************************************/

control DnsIngress(inout headers hdr,
                  inout metadata_t meta,
                  inout standard_metadata_t standard_metadata) {
    action drop() {
        mark_to_drop(standard_metadata);
    }

    action dns_found(ip4Addr_t answer) {
        ip4Addr_t temp32;
        bit<16> temp16;

        temp32 = hdr.ipv4.srcAddr;
        hdr.ipv4.srcAddr = hdr.ipv4.dstAddr;
        hdr.ipv4.dstAddr = temp32;
        hdr.ipv4.totalLen = hdr.ipv4.totalLen + 16;

        temp16 = hdr.udp.srcPort;
        hdr.udp.srcPort = hdr.udp.dstPort;
        hdr.udp.dstPort = temp16;
        hdr.udp.totalLen = hdr.udp.totalLen + 16;
        hdr.udp.checksum = 0;

        hdr.dns.qr = DNS_TYPE_RESPONSE;
        hdr.dns.respCode = DNS_RESP_NOERROR;
        hdr.dns.anCount = 1;

        hdr.dns_answer.setValid();
        hdr.dns_answer.compression = DNS_COMPRESSION;
        hdr.dns_answer.offset = 12;
        hdr.dns_answer.type = DNS_RR_ADDRESS;
        hdr.dns_answer.class = DNS_CLASS_INTERNET;
        hdr.dns_answer.ttl = 64;
        hdr.dns_answer.rdLength = 4;
        hdr.dns_answer.rdData = answer;
    }

    action dns_miss() {
        /* nothing to do, just to forward message*/
    }

    action ipv4_forward(macAddr_t dstAddr, port_t port) {
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 16;
        default_action = drop();
    }

    #include "inc/tables.p4"

    apply {
        if (hdr.ipv4.isValid()) {
            if (hdr.ipv4.ttl == 0) {
                drop();
                exit;
            }

            if (meta.is_dns == 1) {
                if (meta.is_query == 1) {

                #include "inc/apply.p4"

                }
                else {
                    if (hdr.dns_answer.isValid())
                        if (hdr.dns_answer.ttl > 0)
                            hdr.dns_answer.ttl = hdr.dns_answer.ttl - 1;
                }
            }
            ipv4_lpm.apply();
        }
    }
}

/*************************************************************************
******************* E G R E S S     P R O C E S S I N G ******************
*************************************************************************/

control DnsEgress(inout headers hdr,
                 inout metadata_t meta,
                 inout standard_metadata_t standard_metadata) {
    apply {

    }
}

/*************************************************************************
*************** C H E C K S U M     C O M P U T A T I O N ****************
*************************************************************************/

control DnsComputeChecksum(inout headers hdr, inout metadata_t meta) {
    apply {
        update_checksum(hdr.ipv4.isValid(), {
                hdr.ipv4.version,
                hdr.ipv4.ihl,
                hdr.ipv4.diffserv,
                hdr.ipv4.totalLen,
                hdr.ipv4.identification,
                hdr.ipv4.flags,
                hdr.ipv4.fragOffset,
                hdr.ipv4.ttl,
                hdr.ipv4.protocol,
                hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr
            },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/*************************************************************************
************************** D E P A R S E R *******************************
*************************************************************************/

control DnsDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);
        packet.emit(hdr.dns);
        packet.emit(hdr.dns_querylen);
        packet.emit(hdr.dns_querytext);
        packet.emit(hdr.dns_queryopt);
        packet.emit(hdr.dns_answer);
    }
}

/*************************************************************************
*************************** S W I T C H **********************************
*************************************************************************/

V1Switch(DnsParser(), DnsVerifyChecksum(), DnsIngress(), DnsEgress(), DnsComputeChecksum(), DnsDeparser()) main;
