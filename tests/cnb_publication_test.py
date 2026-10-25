import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("publish_cnb", Path(__file__).resolve().parents[1] / "dockerfiles/publish-cnb.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class PublicationBoundaryTests(unittest.TestCase):
    def metadata(self):
        return {"pve_major": "9", "architecture": "arm64", "image": "spiritlhl/pve:9_aarch64",
                "image_id": "sha256:" + "a" * 64,
                "validation_environment": "independent-github-hosted-arm64-vm",
                "validation": {"https_pam": True, "container_restart": True,
                               "password_change_persistent": True, "host_units_masked": True,
                               "qm_boot_reboot": "tcg"},
                "dockerhub": [{"reference": "spiritlhl/pve:9_aarch64", "digest": "sha256:" + "b" * 64,
                               "image_id": "sha256:" + "a" * 64, "architecture": "arm64"}]}

    def test_arm_aliases_keep_amd64_version_tag(self):
        target = publication.validated_target(self.metadata(), "9", "arm64")
        self.assertEqual(target["tags"], ["9_aarch64", "9_arm64"])
        self.assertEqual(target["source"], "docker.io/spiritlhl/pve@sha256:" + "b" * 64)

    def test_reject_incomplete_or_inconsistent_publication(self):
        valid = self.metadata()
        bad = []
        for key in valid["validation"]:
            item = copy.deepcopy(valid)
            del item["validation"][key]
            bad.append(item)
        for key, value in (("architecture", "amd64"), ("image_id", "sha256:bad"),
                           ("validation_environment", "builder"), ("image", "untrusted/pve:9")):
            item = copy.deepcopy(valid)
            item[key] = value
            bad.append(item)
        item = copy.deepcopy(valid)
        item["dockerhub"][0]["image_id"] = "sha256:" + "c" * 64
        bad.append(item)
        for item in bad:
            with self.subTest(metadata=item), self.assertRaises(ValueError):
                publication.validated_target(item, "9", "arm64")


if __name__ == "__main__":
    unittest.main()
