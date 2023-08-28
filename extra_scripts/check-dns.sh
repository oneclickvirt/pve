#!/bin/bash
# from
# https://github.com/spiritLHLS/pve

DNS_SERVER="8.8.8.8"
RESOLV_CONF="/etc/resolv.conf"
ipv6_address=$(cat /usr/local/bin/pve_check_ipv6)
ipv6_prefixlen=$(cat /usr/local/bin/pve_ipv6_prefixlen)
ipv6_gateway=$(cat /usr/local/bin/pve_ipv6_gateway)
grep -q "^nameserver ${DNS_SERVER}$" ${RESOLV_CONF}
if [ $? -eq 0 ]; then
    echo "DNS server ${DNS_SERVER} already exists in ${RESOLV_CONF}."
else
    echo "Adding DNS server ${DNS_SERVER} to ${RESOLV_CONF}..."
    if [ -z "$ipv6_address" ] || [ -z "$ipv6_prefixlen" ] || [ -z "$ipv6_gateway" ]; then
        echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" >>${RESOLV_CONF}
    else
        echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\nnameserver 2001:4860:4860::8844" >>${RESOLV_CONF}
    fi
fi
sleep 3
if grep -q "vmbr0" "/etc/network/interfaces"; then
    resolvconf -a vmbr0 < ${RESOLV_CONF}
fi