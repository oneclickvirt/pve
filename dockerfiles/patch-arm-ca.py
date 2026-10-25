#!/usr/bin/env python3
"""Add RFC 5280 CA extensions missing from older PXVIRT certificate generation."""
from pathlib import Path
import re
import sys


def patch(path):
    source = path.read_text()
    match = re.search(r'(?ms)^sub gen_pveca_cert \{\n.*?(?=^sub \w+)', source)
    if match is None:
        raise RuntimeError('Unrecognized PXVIRT CA generator')
    section = match.group()
    if re.search(r'keyUsage\s*=.*keyCertSign', section):
        print('PXVIRT already specifies the CA signing usage')
        return
    # Scope this to PVE CA creation; leave the system OpenSSL configuration,
    # existing cluster keys/certificates and node certificate generation intact.
    marker = "            'openssl',\n            'req',\n"
    if section.count(marker) != 1 or 'keyUsage' in section:
        raise RuntimeError('Unrecognized PXVIRT CA request; refusing an ambiguous patch')
    replacement = marker + (
        "            '-addext',\n"
        "            'basicConstraints=critical,CA:TRUE',\n"
        "            '-addext',\n"
        "            'keyUsage=critical,keyCertSign,cRLSign',\n"
    )
    patched = section.replace(marker, replacement)
    path.write_text(source[:match.start()] + patched + source[match.end():])
    print('PXVIRT CA generator includes critical constraints and signing usage')


if __name__ == '__main__':
    patch(Path(sys.argv[1]))
