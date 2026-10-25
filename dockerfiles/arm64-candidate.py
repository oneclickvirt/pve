#!/usr/bin/env python3
"""Bind ARM build, disposable native-VM validation and publication to one candidate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = ('image.tar', 'guest.qcow2', 'packages.json', 'guest.json')
CHECKS = {'https_pam': True, 'qm_boot_reboot': 'tcg', 'container_restart': True,
          'password_change_persistent': True, 'host_units_masked': True}


def output(command):
    return subprocess.check_output(command, text=True, timeout=180).strip()


def run(command, **kwargs):
    return subprocess.run(command, check=True, timeout=kwargs.pop('timeout', 1800), **kwargs)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def identity():
    if os.environ.get('GITHUB_REPOSITORY') != 'oneclickvirt/pve':
        raise RuntimeError('Candidate requires the PVE repository workflow')
    source = output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'])
    if source != os.environ.get('GITHUB_SHA') or not re.fullmatch(r'[0-9a-f]{40}', source):
        raise RuntimeError('Workflow and checked-out source differ')
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
    if not run_id.isdigit() or not attempt.isdigit():
        raise RuntimeError('Missing workflow run identity')
    return {'source_sha': source, 'run_id': run_id, 'run_attempt': attempt}


def prepare(folder, major, image, destination):
    source = identity()
    if destination.exists():
        raise RuntimeError('Candidate destination must be new')
    if output(['docker', 'image', 'inspect', '--format', '{{.Architecture}}', image]) != 'arm64':
        raise RuntimeError('Candidate is not ARM64')
    packages = json.loads((folder / 'packages.json').read_text())
    if packages.get('distribution') != 'pxvirt':
        raise RuntimeError('Candidate is not PXVIRT')
    version = output(['docker', 'run', '--rm', '--entrypoint', 'dpkg-query', image,
                      '-W', '-f=${Version}', 'pve-manager'])
    if not version.startswith(major + '.'):
        raise RuntimeError('Candidate version differs')
    candidate = {**source, 'major': major, 'architecture': 'arm64', 'version': version,
                 'image': image, 'image_id': output(['docker', 'image', 'inspect', '--format', '{{.Id}}', image]),
                 'files': {name: {'size': (folder / name).stat().st_size,
                                  'sha256': digest(folder / name)} for name in FILES}}
    destination.mkdir(parents=True)
    for name in FILES:
        shutil.move(str(folder / name), destination / name)
    (destination / 'candidate.json').write_text(json.dumps(candidate, indent=2) + '\n')
    print('ARM64 candidate prepared; publication requires independent runtime validation', flush=True)


def verify(folder, major):
    candidate = json.loads((folder / 'candidate.json').read_text())
    source = identity()
    if any(candidate.get(key) != value for key, value in source.items()):
        raise RuntimeError('Candidate belongs to another workflow source or run')
    if candidate.get('major') != major or candidate.get('architecture') != 'arm64':
        raise RuntimeError('Candidate version or architecture mismatch')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', candidate.get('image_id', '')):
        raise RuntimeError('Invalid candidate image identity')
    if not re.fullmatch(r'oneclickvirt-pve-[a-z0-9.-]+:[89]', candidate.get('image', '')):
        raise RuntimeError('Invalid candidate image reference')
    if not candidate.get('version', '').startswith(major + '.') or set(candidate.get('files', {})) != set(FILES):
        raise RuntimeError('Invalid candidate metadata')
    for name in FILES:
        path = folder / name
        if path.is_symlink() or not path.is_file():
            raise RuntimeError('Missing regular candidate payload: ' + name)
        if candidate['files'][name] != {'size': path.stat().st_size, 'sha256': digest(path)}:
            raise RuntimeError('Candidate payload checksum mismatch: ' + name)
    return candidate


def load(folder, candidate):
    run(['docker', 'load', '-i', str(folder / 'image.tar')])
    if output(['docker', 'image', 'inspect', '--format', '{{.Id}}', candidate['image']]) != candidate['image_id']:
        raise RuntimeError('Loaded candidate image differs')
    if output(['docker', 'image', 'inspect', '--format', '{{.Architecture}}', candidate['image']]) != 'arm64':
        raise RuntimeError('Loaded image is not ARM64')


def require_disposable_host():
    expected = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                'RUNNER_ARCH': 'ARM64', 'RUNNER_OS': 'Linux'}
    if any(os.environ.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Runtime validation requires a fresh GitHub-hosted ARM64 VM')
    if platform.machine() != 'aarch64' or Path('/.dockerenv').exists():
        raise RuntimeError('Runtime validation requires a complete native ARM64 VM')
    if any(os.environ.get(key) for key in ('GH_TOKEN', 'GITHUB_TOKEN', 'DOCKER_PASSWORD', 'DOCKER_AUTH_CONFIG')):
        raise RuntimeError('Runtime validation must not receive publication credentials')
    run(['systemd-detect-virt', '--vm'], stdout=subprocess.DEVNULL)


def validate(folder, major, report_path):
    require_disposable_host()
    candidate = verify(folder, major)
    load(folder, candidate)
    run(['sudo', 'modprobe', '-a', 'fuse', 'tun'])
    if not Path('/dev/fuse').exists() or not Path('/dev/net/tun').exists():
        raise RuntimeError('Disposable VM lacks required devices')
    run(['sudo', 'touch', '/run/cnb-disposable-build'])
    command = [sys.executable, '-u', str(ROOT / 'tests/pve_container_runtime.py'),
               candidate['image'], major, str(folder / 'guest.qcow2')]
    # Stream progress while retaining the final structured runtime result.
    process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
    result = None
    try:
        for line in process.stdout:
            print(line, end='', flush=True)
            if line.startswith('PVE_DOCKER_RUNTIME_OK '):
                if result is not None:
                    raise RuntimeError('Duplicate runtime validation result')
                result = json.loads(line.removeprefix('PVE_DOCKER_RUNTIME_OK '))
        if process.wait() != 0:
            raise RuntimeError('PVE runtime validation failed')
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=15)
    expected = {**CHECKS, 'major': major, 'version': candidate['version'],
                'architecture': 'arm64', 'distribution': 'pxvirt'}
    if result != expected:
        raise RuntimeError('Runtime checks did not all pass for this candidate')
    report = {**identity(), 'major': major, 'image_id': candidate['image_id'],
              'candidate_sha256': digest(folder / 'candidate.json'),
              'environment': 'independent-github-hosted-arm64-vm', 'checks': result}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print('Independent native ARM64 VM validation passed', flush=True)


def verify_report(folder, candidate, report_path):
    report = json.loads(report_path.read_text())
    expected = {**identity(), 'major': candidate['major'], 'image_id': candidate['image_id'],
                'candidate_sha256': digest(folder / 'candidate.json'),
                'environment': 'independent-github-hosted-arm64-vm',
                'checks': {**CHECKS, 'major': candidate['major'], 'version': candidate['version'],
                           'architecture': 'arm64', 'distribution': 'pxvirt'}}
    if report != expected:
        raise RuntimeError('Missing or mismatched successful independent validation')
    return report


def publish(folder, major, report_path):
    candidate = verify(folder, major)
    report = verify_report(folder, candidate, report_path)
    if not os.environ.get('GH_TOKEN'):
        raise RuntimeError('Release publication requires a credential')
    load(folder, candidate)
    references = [f'spiritlhl/pve:{major}_aarch64', f'spiritlhl/pve:{major}_arm64',
                  f'oneclickvirt/pve:{major}_aarch64']
    for reference in references:
        run(['docker', 'tag', candidate['image'], reference])
    for reference in references[:2]:
        run(['docker', 'push', reference])
    hub = folder / 'dockerhub.json'
    run([sys.executable, str(ROOT / 'dockerfiles/verify-hub.py'), candidate['image_id'],
         str(hub), *references[:2], '--architecture', 'arm64'])
    archive = folder / f'pve{major}-arm64.tar.gz'
    with archive.open('wb') as stream:
        save = subprocess.Popen(['docker', 'save', *references], stdout=subprocess.PIPE)
        try:
            run(['gzip', '-1'], stdin=save.stdout, stdout=stream)
            save.stdout.close()
            if save.wait(timeout=180) != 0:
                raise RuntimeError('Docker image export failed')
        finally:
            if save.poll() is None:
                save.terminate()
                save.wait(timeout=30)
    checksum = digest(archive)
    (folder / 'SHA256SUMS-arm64').write_text(checksum + '  ' + archive.name + '\n')
    metadata = {'pve_major': major, 'pve_version': candidate['version'],
                'source_sha': candidate['source_sha'], 'architecture': 'arm64',
                'image': references[0], 'image_aliases': references[1:],
                'packages': json.loads((folder / 'packages.json').read_text()),
                'image_id': candidate['image_id'], 'dockerhub': json.loads(hub.read_text()),
                'archive': archive.name, 'size': archive.stat().st_size, 'sha256': checksum,
                'validation': CHECKS, 'validation_environment': report['environment'],
                'test_guest': json.loads((folder / 'guest.json').read_text())}
    (folder / 'build-arm64.json').write_text(json.dumps(metadata, indent=2) + '\n')
    run([sys.executable, str(ROOT / 'dockerfiles/release_assets.py'), 'docker-pve' + major,
         str(archive), str(folder / 'SHA256SUMS-arm64'), str(folder / 'build-arm64.json')])
    print(f'ARM64 PVE {major} validated and published to Docker Hub and GitHub Release', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['prepare', 'verify', 'validate', 'publish'])
    parser.add_argument('folder', type=Path)
    parser.add_argument('major', choices=['8', '9'])
    parser.add_argument('extra', nargs='*')
    args = parser.parse_args()
    if args.mode == 'prepare' and len(args.extra) == 2:
        prepare(args.folder, args.major, args.extra[0], Path(args.extra[1]))
    elif args.mode == 'verify' and not args.extra:
        verify(args.folder, args.major)
    elif args.mode in ('validate', 'publish') and len(args.extra) == 1:
        globals()[args.mode](args.folder, args.major, Path(args.extra[0]))
    else:
        parser.error('Invalid candidate command arguments')


if __name__ == '__main__':
    main()
