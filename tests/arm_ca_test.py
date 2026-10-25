#!/usr/bin/env python3
"""Check PXVIRT CA compatibility using real strict OpenSSL verification."""
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'dockerfiles/patch-arm-ca.py'
spec = importlib.util.spec_from_file_location('arm_ca_patch', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# The relevant command layout in PXVIRT pve-cluster 9.0.6.
SOURCE = '''sub gen_pveca_cert {
    eval {
        run_silent_cmd([
            'faketime',
            'yesterday',
            'openssl',
            'req',
            '-batch',
            '-days',
            '3650',
            '-new',
            '-x509',
            '-nodes',
            '-key',
            $pveca_key_fn,
            '-out',
            $pveca_cert_fn,
        ]);
    };
}

sub gen_pve_ssl_key {
    # Node keys are not part of this compatibility patch.
}
'''


class ARMCA(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'Setup.pm'
        self.source.write_text(SOURCE)

    def run_openssl(self, *args, check=True):
        return subprocess.run(['openssl', *args], cwd=self.root, check=check,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)

    def test_strict_verification_of_generated_chain(self):
        module.patch(self.source)
        patched = self.source.read_text()
        extra = []
        for extension in re.findall(r"'-addext',\s*'([^']+)'", patched):
            extra += ['-addext', extension]
        self.assertEqual(len(extra), 4)
        (self.root / 'ca.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ca\n'
            '[dn]\n[ca]\nbasicConstraints=critical,CA:TRUE\nsubjectKeyIdentifier=hash\n')
        self.run_openssl('genrsa', '-out', 'ca.key', '2048')
        for name, options in [('legacy', []), ('patched', extra)]:
            self.run_openssl('req', '-new', '-x509', '-key', 'ca.key', '-days', '1',
                '-subj', '/CN=test-ca', '-config', 'ca.cnf', '-out', name + '.pem', *options)
        self.run_openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=test-node',
                         '-keyout', 'node.key', '-out', 'node.csr')
        (self.root / 'leaf.cnf').write_text('basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n'
            'subjectAltName=DNS:test-node\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n')
        self.run_openssl('x509', '-req', '-in', 'node.csr', '-days', '1', '-CA', 'patched.pem',
            '-CAkey', 'ca.key', '-CAcreateserial', '-extfile', 'leaf.cnf', '-out', 'node.pem')
        legacy = self.run_openssl('verify', '-x509_strict', '-purpose', 'sslserver',
            '-verify_hostname', 'test-node', '-CAfile', 'legacy.pem', 'node.pem', check=False)
        self.assertNotEqual(legacy.returncode, 0)
        self.assertIn('key usage', legacy.stderr.lower())
        self.run_openssl('verify', '-x509_strict', '-purpose', 'sslserver',
            '-verify_hostname', 'test-node', '-CAfile', 'patched.pem', 'node.pem')

    def test_patch_is_idempotent_and_scoped(self):
        module.patch(self.source)
        first = self.source.read_text()
        module.patch(self.source)
        self.assertEqual(self.source.read_text(), first)
        self.assertEqual(first.split('sub gen_pve_ssl_key')[1], SOURCE.split('sub gen_pve_ssl_key')[1])

    def test_unknown_generator_fails_without_editing(self):
        self.source.write_text('sub gen_pveca_cert {\n    changed_upstream();\n}\nsub next {}\n')
        before = self.source.read_bytes()
        with self.assertRaises(RuntimeError):
            module.patch(self.source)
        self.assertEqual(self.source.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
