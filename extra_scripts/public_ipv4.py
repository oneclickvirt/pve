"""Validate public guest IPv4 against live topology and all PVE guest configs."""
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys


def choose(mode, requested, addresses, routes, used):
    hosts = {ipaddress.IPv4Address(info['local']) for row in addresses
             for info in row.get('addr_info', []) if info.get('family') == 'inet'}
    candidates = [row for row in routes if row.get('dst') == 'default'
                  and row.get('dev') == 'vmbr0' and row.get('gateway')]
    if len(candidates) != 1:
        raise ValueError('vmbr0 must have one unambiguous IPv4 default gateway')
    gateway = ipaddress.IPv4Address(candidates[0]['gateway'])
    networks = [ipaddress.IPv4Interface(f"{info['local']}/{info['prefixlen']}")
                for row in addresses if row.get('ifname') == 'vmbr0'
                for info in row.get('addr_info', []) if info.get('family') == 'inet'
                and info.get('scope') == 'global']
    networks = [value for value in networks if gateway in value.network]
    networks.sort(key=lambda value: value.network.prefixlen, reverse=True)
    if not networks:
        raise ValueError('vmbr0 lacks a static subnet containing its gateway')
    primary = networks[0]
    subnet = primary.network
    excluded = hosts | {gateway, subnet.network_address, subnet.broadcast_address} | used
    if mode == 'auto':
        if subnet.num_addresses > 65536:
            raise ValueError('automatic allocation requires an explicitly bounded subnet')
        values = (address for address in subnet.hosts() if int(address) > int(primary.ip))
        for address in values:
            if address not in excluded:
                return address, primary.network.prefixlen, gateway, primary.ip
        raise ValueError('no unallocated address remains after the host address')
    if mode not in {'manual', 'fullnat'}:
        raise ValueError('unknown IPv4 allocation mode')
    value = ipaddress.IPv4Interface(requested)
    address = value.ip
    if address not in subnet:
        raise ValueError('address is outside the live bridge subnet; a separately routed /32 needs an explicit upstream route and guest topology')
    if mode == 'fullnat':
        if address not in hosts or address in {primary.ip, gateway} or address in used:
            raise ValueError('full NAT requires a separate host alias not assigned to any guest')
    else:
        if address in excluded:
            raise ValueError('guest IPv4 conflicts with a host, gateway, reserved or existing guest address')
        if value.network.prefixlen != subnet.prefixlen:
            raise ValueError(f'bridged IPv4 prefix must match the actual /{subnet.prefixlen} subnet')
    return address, subnet.prefixlen, gateway, primary.ip


def live(mode, requested):
    def snapshot(args):
        return json.loads(subprocess.check_output(['ip', '-j', '-4', *args], text=True, timeout=15))
    used = set()
    for pattern in ('*/qemu-server/*.conf', '*/lxc/*.conf'):
        for config in Path('/etc/pve/nodes').glob(pattern):
            for line in config.read_text().splitlines():
                if re.match(r'^# oneclickvirt-fullnat-ipv4 ', line):
                    used.add(ipaddress.IPv4Address(line.split()[-1]))
                elif re.match(r'^# (?:外网IP地址-ipv4|外网IPV4-ipv4) ', line):
                    used.add(ipaddress.IPv4Address(line.split()[-1]))
                elif re.match(r'^(?:net|ipconfig)\d+:', line):
                    for value in re.findall(r'(?:^|[, ])ip=([0-9.]+)(?:/\d+)?', line):
                        used.add(ipaddress.IPv4Address(value))
    result = choose(mode, requested, snapshot(['addr', 'show']), snapshot(['route', 'show', 'default']), used)
    if mode != 'fullnat':
        # Silence from ICMP is not evidence that an address is free. ARP DAD
        # also checks live devices which are not managed by this PVE cluster.
        probe = subprocess.run(['arping', '-D', '-I', 'vmbr0', '-c', '2', '-w', '3', str(result[0])],
                               capture_output=True, timeout=8)
        if probe.returncode != 0:
            raise ValueError('IPv4 duplicate-address probe failed; address was not allocated')
    return result


if __name__ == '__main__':
    try:
        for item in live(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ''):
            print(item)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('Public IPv4 preflight failed: '+str(error))
