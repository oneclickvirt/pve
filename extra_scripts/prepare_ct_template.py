"""Remove device nodes from a cached PVE template without extracting its rootfs.

Old vzdump templates may have /var/spool/postfix/dev/{random,urandom}.
PVE's user-namespace unpack cannot create those nodes. GNU tar --delete retains
the other tar records, numeric owners, ACLs, xattrs, hardlinks and sparse data.
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


def fingerprint(path):
    info = path.stat()
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns]


def prepare(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        raise ValueError('PVE template must be a regular cached file')
    suffix = path.name.lower()
    codecs = [('.tar.zst', ['zstd', '-dc'], ['zstd', '-T2', '-3', '-c']),
              ('.tar.xz', ['xz', '-dc'], ['xz', '-T2', '-3', '-c']),
              ('.tar.gz', ['gzip', '-dc'], ['gzip', '-3', '-c']),
              ('.tar.bz2', ['bzip2', '-dc'], ['bzip2', '-c']),
              ('.tar', ['cat'], ['cat'])]
    selected = next((row for row in codecs if suffix.endswith(row[0])), None)
    if selected is None:
        raise ValueError('Unsupported PVE template compression')
    marker = path.with_name(path.name + '.ocv-unprivileged-v1')
    lock = path.with_name(path.name + '.ocv-template.lock')
    with lock.open('a') as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        current = fingerprint(path)
        try:
            if json.loads(marker.read_text()) == current:
                return 0
        except (OSError, ValueError):
            pass
        with tempfile.TemporaryDirectory(prefix='.ocv-template-', dir=path.parent) as folder:
            folder = Path(folder)
            raw = folder/'rootfs.tar'
            budget = min(20 << 30, shutil.disk_usage(folder).free - (256 << 20))
            if budget <= path.stat().st_size:
                raise RuntimeError('Insufficient space to prepare PVE template')
            unpack = subprocess.Popen([*selected[1], str(path)], stdout=subprocess.PIPE)
            try:
                size = 0
                with raw.open('wb') as output:
                    while chunk := unpack.stdout.read(1 << 20):
                        size += len(chunk)
                        if size > budget:
                            raise RuntimeError('PVE template exceeds available preparation space')
                        output.write(chunk)
                if unpack.wait(timeout=30):
                    raise RuntimeError('PVE template decompression failed')
            finally:
                unpack.stdout.close()
                if unpack.poll() is None:
                    unpack.kill()
                    unpack.wait()
            subprocess.run(['tar', '-tf', str(raw)], check=True,
                           stdout=subprocess.DEVNULL, timeout=180)
            nodes = []
            with tarfile.open(raw, 'r:') as archive:
                for count, member in enumerate(archive):
                    if count > 500000:
                        raise ValueError('PVE template has too many records')
                    if member.ischr() or member.isblk():
                        nodes.append(member.name)
            if nodes:
                names = folder/'devices'
                names.write_bytes(b''.join(name.encode('utf-8', 'surrogateescape')+b'\0' for name in nodes))
                subprocess.run(['tar', '--delete', '--file', str(raw), '--null',
                                '--verbatim-files-from', '--files-from', str(names)], check=True, timeout=300)
                replacement = folder/path.name
                with replacement.open('wb') as output:
                    subprocess.run([*selected[2], str(raw)], stdout=output, check=True, timeout=600)
                    output.flush()
                    os.fsync(output.fileno())
                shutil.copystat(path, replacement)
                os.replace(replacement, path)
            marker_temp = folder/'verified'
            marker_temp.write_text(json.dumps(fingerprint(path)))
            os.replace(marker_temp, marker)
            return len(nodes)


if __name__ == '__main__':
    print('PVE unprivileged template ready; removed device nodes:', prepare(sys.argv[1]))
