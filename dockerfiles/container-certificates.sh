#!/usr/bin/env bash
set -Eeuo pipefail

root=${1:-/etc/pve}
certificate=$root/local/pve-ssl.pem
key=$root/local/pve-ssl.key
ca=$root/pve-root-ca.pem

valid_pair() {
    [[ -s "$certificate" && -s "$key" && -s "$ca" ]] || return 1
    openssl verify -CAfile "$ca" "$certificate" >/dev/null 2>&1 || return 1
    openssl x509 -in "$certificate" -noout -checkend 300 >/dev/null 2>&1 || return 1
    local public private
    public=$(openssl x509 -in "$certificate" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum) || return 1
    private=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum) || return 1
    [[ "$public" == "$private" ]]
}

# Some PXVIRT first boots leave a valid node key but no node certificate.
# Do not start a proxy that only accepts TCP and then fails every TLS handshake.
# Preserve existing valid certificates and the cluster CA on container restarts.
for attempt in {1..12}; do
    if valid_pair; then
        echo 'PVE node certificate chain and key verified'
        exit 0
    fi
    echo "Preparing PVE node certificate (attempt $attempt)"
    pvecm updatecerts --force || true
    if valid_pair; then
        echo 'PVE node certificate chain and key verified'
        exit 0
    fi
    sleep 5
done
echo 'PVE node certificate could not be prepared; proxy startup blocked' >&2
exit 1
