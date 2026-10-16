import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('template_helper', Path(__file__).resolve().parents[1]/'extra_scripts'/'prepare_ct_template.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class TemplateTests(unittest.TestCase):
    def test_devices_removed_and_metadata_retained(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'rootfs.tar.gz'
            with tarfile.open(path, 'w:gz', format=tarfile.PAX_FORMAT) as archive:
                normal = tarfile.TarInfo('./etc/example')
                normal.size, normal.uid, normal.gid, normal.mode = 4, 1001, 1002, 0o640
                normal.pax_headers = {'SCHILY.xattr.user.test': 'retained'}
                archive.addfile(normal, io.BytesIO(b'data'))
                hardlink = tarfile.TarInfo('./etc/linked')
                hardlink.type, hardlink.linkname = tarfile.LNKTYPE, './etc/example'
                archive.addfile(hardlink)
                for name in ['./var/spool/postfix/dev/random', './dev/urandom']:
                    node = tarfile.TarInfo(name)
                    node.type, node.devmajor, node.devminor = tarfile.CHRTYPE, 1, 9
                    archive.addfile(node)
            self.assertEqual(helper.prepare(path), 2)
            with tarfile.open(path) as archive:
                self.assertFalse(any(row.ischr() or row.isblk() for row in archive))
                normal = archive.getmember('./etc/example')
                self.assertEqual((normal.uid, normal.gid, normal.mode), (1001, 1002, 0o640))
                self.assertEqual(normal.pax_headers['SCHILY.xattr.user.test'], 'retained')
                self.assertEqual(archive.extractfile(normal).read(), b'data')
                self.assertEqual(archive.getmember('./etc/linked').linkname, './etc/example')
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(helper.prepare(path), 0)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)

    def test_corrupt_archive_never_replaces_original_or_marks_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'broken.tar.gz'
            path.write_bytes(b'broken')
            with self.assertRaises(RuntimeError):
                helper.prepare(path)
            self.assertEqual(path.read_bytes(), b'broken')
            self.assertFalse(path.with_name(path.name+'.ocv-unprivileged-v1').exists())


if __name__ == '__main__':
    unittest.main()
