"""Manual, independent password-SSH proof. Targets remain Actions secrets."""
from concurrent.futures import ThreadPoolExecutor
import base64
import hashlib
import ipaddress
import json
import logging
import os
import secrets
import sys
import time

import paramiko

logging.getLogger('paramiko').addHandler(logging.NullHandler())
logging.getLogger('paramiko').propagate = False


class HostKeyMismatch(paramiko.SSHException):
    pass


class PinnedHostKey(paramiko.MissingHostKeyPolicy):
    def __init__(self, expected):
        self.expected = expected

    def missing_host_key(self, client, hostname, key):
        actual = 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')
        if actual != self.expected:
            raise HostKeyMismatch('Host key does not match the supplied fingerprint')


def targets_from_environment():
    rows = json.loads(os.environ.get('RUNTIME_NETWORK_SSH_TARGETS', '[]'))
    if not isinstance(rows, list) or not 1 <= len(rows) <= 24:
        raise ValueError('Supply between one and twenty-four disposable targets')
    for row in rows:
        address = ipaddress.ip_address(row['address'])
        if not address.is_global:
            raise ValueError('Each target must have a global IPv4/IPv6 address')
        if not row.get('password') or not row.get('fingerprint', '').startswith('SHA256:'):
            raise ValueError('Password and host-key fingerprint are required')
        port = int(row.get('port', 22))
        if not 1 <= port <= 65535:
            raise ValueError('Target port is invalid')
        row['address'], row['port'] = str(address), port
    return rows


def probe(row):
    deadline = time.monotonic() + 120
    last_type = 'Unavailable'
    while time.monotonic() < deadline:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(PinnedHostKey(row['fingerprint']))
        connection = None
        try:
            proxy = os.environ.get('RUNTIME_IPV6_SOCKS', '') if ipaddress.ip_address(row['address']).version == 6 else ''
            if proxy:
                import socks
                host, port = proxy.rsplit(':', 1)
                connection = socks.socksocket()
                connection.set_proxy(socks.SOCKS5, host, int(port))
                connection.settimeout(12)
                connection.connect((row['address'], row['port']))
            client.connect(row['address'], port=row['port'], username=row.get('username', 'root'),
                           password=row['password'], look_for_keys=False, allow_agent=False,
                           timeout=12, banner_timeout=12, auth_timeout=12, sock=connection)
            nonce = secrets.token_hex(24)
            _, out, err = client.exec_command("printf '%s\\n' '" + nonce + "'; id -u; cat /proc/sys/kernel/random/boot_id", timeout=15)
            lines = out.read(4096).decode().splitlines()
            err.read(4096)
            status = out.channel.recv_exit_status()
            if status or len(lines) != 3 or lines[0] != nonce or lines[1] != '0':
                raise ValueError('Authenticated guest command proof failed')
            if row.get('boot_id') and lines[2] != row['boot_id']:
                raise ValueError('Guest boot identity changed during the proof')
            return {'password_authenticated': True, 'pinned_host_key': True,
                    'root_command_nonce': True, 'transport': 'independent_ipv'+str(ipaddress.ip_address(row['address']).version)}
        except HostKeyMismatch:
            return {'password_authenticated': False, 'failure_type': 'HostKeyMismatch'}
        except (OSError, paramiko.SSHException) as error:
            last_type = type(error).__name__
        finally:
            client.close()
            if connection is not None:
                connection.close()
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    # No target, exception text, command output, or credential reaches logs.
    return {'password_authenticated': False, 'failure_type': last_type}


def main():
    try:
        rows = targets_from_environment()
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = [dict(guest=index + 1, **result) for index, result in enumerate(pool.map(probe, rows))]
        print(json.dumps({'results': results}, sort_keys=True))
        return 0 if all(row['password_authenticated'] for row in results) else 1
    except Exception as error:
        print(json.dumps({'probe_failed': True, 'failure_type': type(error).__name__}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
