#!/usr/bin/env python3
"""Exercise certificate startup with real local CA, leaf and mismatched keys."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'dockerfiles/container-certificates.sh'


class CertificateStartup(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.root = self.folder / 'pve'
        self.local = self.root / 'local'
        self.local.mkdir(parents=True)
        self.bin = self.folder / 'bin'
        self.bin.mkdir()
        self.calls = self.folder / 'calls'
        self.environment = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                            'CERT_TEST_ROOT': str(self.root), 'CERT_TEST_FOLDER': str(self.folder)}
        commands = [
            ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=test-ca',
             '-keyout', str(self.folder / 'ca.key'), '-out', str(self.root / 'pve-root-ca.pem')],
            ['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=test-node',
             '-keyout', str(self.folder / 'node.key'), '-out', str(self.folder / 'node.csr')],
            ['openssl', 'x509', '-req', '-in', str(self.folder / 'node.csr'), '-days', '1',
             '-CA', str(self.root / 'pve-root-ca.pem'), '-CAkey', str(self.folder / 'ca.key'),
             '-CAcreateserial', '-out', str(self.folder / 'node.pem')],
        ]
        for command in commands:
            subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        self.mock('sleep', '#!/bin/sh\nexit 0\n')

    def mock(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def install_pair(self):
        shutil.copyfile(self.folder / 'node.pem', self.local / 'pve-ssl.pem')
        shutil.copyfile(self.folder / 'node.key', self.local / 'pve-ssl.key')

    def invoke(self):
        return subprocess.run(['bash', str(SCRIPT), str(self.root)], env=self.environment,
                              capture_output=True, text=True, timeout=30)

    def test_valid_certificate_is_preserved_without_regeneration(self):
        self.install_pair()
        self.mock('pvecm', '#!/bin/sh\necho unexpected > "$CERT_TEST_FOLDER/calls"\nexit 1\n')
        before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in self.local.iterdir()}
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())
        self.assertEqual(before, {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in self.local.iterdir()})

    def test_missing_certificate_is_regenerated_and_verified(self):
        shutil.copyfile(self.folder / 'node.key', self.local / 'pve-ssl.key')
        self.mock('pvecm', '#!/bin/sh\necho "$*" >> "$CERT_TEST_FOLDER/calls"\n'
                  'cp "$CERT_TEST_FOLDER/node.pem" "$CERT_TEST_ROOT/local/pve-ssl.pem"\n')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ['updatecerts --force'])

    def test_mismatched_key_and_failed_generation_block_startup(self):
        self.install_pair()
        shutil.copyfile(self.folder / 'ca.key', self.local / 'pve-ssl.key')
        self.mock('pvecm', '#!/bin/sh\necho "$*" >> "$CERT_TEST_FOLDER/calls"\nexit 1\n')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('proxy startup blocked', result.stderr)
        self.assertEqual(len(self.calls.read_text().splitlines()), 12)


if __name__ == '__main__':
    unittest.main()
