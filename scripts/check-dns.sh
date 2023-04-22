#!/bin/bash
#from https://github.com/spiritLHLS/pve

DNS_SERVER="8.8.8.8"
RESOLV_CONF="/etc/resolv.conf"

grep -q "^nameserver ${DNS_SERVER}$" ${RESOLV_CONF}

if [ $? -eq 0 ]; then
    echo "DNS server ${DNS_SERVER} already exists in ${RESOLV_CONF}."
else
    echo "Adding DNS server ${DNS_SERVER} to ${RESOLV_CONF}..."
    echo "nameserver ${DNS_SERVER}" >> ${RESOLV_CONF}
fi
