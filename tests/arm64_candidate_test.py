#!/usr/bin/env python3
"""Ensure ARM publication rejects altered candidates and validation reports."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('candidate', Path(__file__).resolve().parents[1] / 'dockerfiles/arm64-candidate.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class CandidateChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.source = {'source_sha': 'a' * 40, 'run_id': '12', 'run_attempt': '1'}
        self.identity = patch.object(candidate, 'identity', return_value=self.source)
        self.identity.start()
        self.addCleanup(self.identity.stop)
        for name in candidate.FILES:
            (self.folder / name).write_text(name)
        self.data = {**self.source, 'major': '9', 'architecture': 'arm64', 'version': '9.0.10-2',
                     'image': 'oneclickvirt-pve-test:9', 'image_id': 'sha256:' + 'b' * 64,
                     'files': {name: {'size': (self.folder / name).stat().st_size,
                                      'sha256': candidate.digest(self.folder / name)} for name in candidate.FILES}}
        self.save()

    def save(self):
        (self.folder / 'candidate.json').write_text(json.dumps(self.data))

    def report(self):
        return {**self.source, 'major': '9', 'image_id': self.data['image_id'],
                'candidate_sha256': candidate.digest(self.folder / 'candidate.json'),
                'environment': 'independent-github-hosted-arm64-vm',
                'checks': {**candidate.CHECKS, 'major': '9', 'version': '9.0.10-2',
                           'architecture': 'arm64', 'distribution': 'pxvirt'}}

    def test_matching_candidate_and_report(self):
        data = candidate.verify(self.folder, '9')
        path = self.folder / 'validation.json'
        path.write_text(json.dumps(self.report()))
        candidate.verify_report(self.folder, data, path)

    def test_changed_payload_or_symlink_is_rejected(self):
        path = self.folder / 'image.tar'
        path.write_text('tampered')
        with self.assertRaises(RuntimeError):
            candidate.verify(self.folder, '9')
        path.unlink()
        path.symlink_to(self.folder / 'guest.qcow2')
        with self.assertRaises(RuntimeError):
            candidate.verify(self.folder, '9')

    def test_other_version_architecture_run_or_source_is_rejected(self):
        for key, value in [('major', '8'), ('architecture', 'amd64'), ('run_id', '13'),
                           ('run_attempt', '2'), ('source_sha', 'c' * 40)]:
            with self.subTest(key=key):
                original = self.data[key]
                self.data[key] = value
                self.save()
                with self.assertRaises(RuntimeError):
                    candidate.verify(self.folder, '9')
                self.data[key] = original

    def test_incomplete_or_unbound_validation_is_rejected_before_docker(self):
        good = self.report()
        changed = [dict(good, image_id='sha256:' + 'd' * 64),
                   dict(good, candidate_sha256='e' * 64),
                   dict(good, run_id='99'), dict(good, environment='local'),
                   dict(good, checks={**good['checks'], 'container_restart': False})]
        for value in changed:
            with self.subTest(value=value):
                path = self.folder / 'validation.json'
                path.write_text(json.dumps(value))
                with patch.object(candidate, 'load') as load, self.assertRaises(RuntimeError):
                    candidate.publish(self.folder, '9', path)
                load.assert_not_called()

    def test_local_host_and_publisher_credentials_are_rejected(self):
        with patch.dict(candidate.os.environ, {}, clear=True), self.assertRaises(RuntimeError):
            candidate.require_disposable_host()
        hosted = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                  'RUNNER_ARCH': 'ARM64', 'RUNNER_OS': 'Linux', 'GH_TOKEN': 'test-only'}
        with patch.dict(candidate.os.environ, hosted, clear=True), \
             patch.object(candidate.platform, 'machine', return_value='aarch64'), \
             patch.object(candidate.Path, 'exists', return_value=False), \
             patch.object(candidate, 'run') as run, self.assertRaises(RuntimeError):
            candidate.require_disposable_host()
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
