// +build ignore

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

// BPF Map to store the token payload count per LLM Pod IP.
// This allows zero-overhead telemetry by entirely bypassing Prometheus scraping.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);   // Source IP Address (Pod IP)
    __type(value, __u64); // Payload Byte Count (proxy for Token Count)
} token_byte_tracker SEC(".maps");

// eBPF hook attached to the Linux Traffic Control (TC) egress layer.
// This intercepts TCP packets leaving the node before they hit the physical NIC.
SEC("tc")
int count_llm_egress_tokens(struct __sk_buff *skb) {
    void *data_end = (void *)(long)skb->data_end;
    void *data = (void *)(long)skb->data;

    // Parse Ethernet header
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_OK;

    // Only inspect IPv4 traffic
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return TC_ACT_OK;

    // Parse IP header
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return TC_ACT_OK;

    // Only inspect TCP traffic (gRPC / HTTP2 used by vLLM / TGI)
    if (ip->protocol != IPPROTO_TCP)
        return TC_ACT_OK;

    struct tcphdr *tcp = (void *)ip + (ip->ihl * 4);
    if ((void *)(tcp + 1) > data_end)
        return TC_ACT_OK;

    // Calculate TCP payload size (Total IP length - IP header - TCP header)
    __u16 ip_len = bpf_ntohs(ip->tot_len);
    __u16 ip_hdr_len = ip->ihl * 4;
    __u16 tcp_hdr_len = tcp->doff * 4;
    
    // Ignore malformed packets
    if (ip_len < ip_hdr_len + tcp_hdr_len)
        return TC_ACT_OK;

    __u16 payload_len = ip_len - ip_hdr_len - tcp_hdr_len;

    // Only track packets with actual data (ignore SYN/ACK overhead)
    if (payload_len > 0) {
        __u32 src_ip = ip->saddr;
        __u64 *byte_count = bpf_map_lookup_elem(&token_byte_tracker, &src_ip);
        if (byte_count) {
            __sync_fetch_and_add(byte_count, payload_len);
        } else {
            __u64 initial = payload_len;
            bpf_map_update_elem(&token_byte_tracker, &src_ip, &initial, BPF_ANY);
        }
    }

    return TC_ACT_OK;
}

char __license[] SEC("license") = "GPL";
