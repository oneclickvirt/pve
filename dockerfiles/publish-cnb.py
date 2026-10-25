#!/usr/bin/env python3
"""Copy only digest-bound, runtime-validated Release images to CNB."""

import hashlib
import json
import re
import subprocess
import time
import urllib.request


DESTINATION = "docker.cnb.cool/oneclickvirt/pve/pve"
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
TARGETS = (("7", "amd64"), ("8", "amd64"), ("9", "amd64"),
           ("8", "arm64"), ("9", "arm64"))


def download_metadata(major, arch):
    name = "build.json" if arch == "amd64" else "build-arm64.json"
    url = f"https://github.com/oneclickvirt/pve/releases/download/docker-pve{major}/{name}"
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "OneClickVirt-CNB-mirror"})
            with urllib.request.urlopen(req, timeout=60) as response:
                return json.load(response)
        except Exception:
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)


def validated_target(metadata, major, arch):
    tag = major if arch == "amd64" else major + "_aarch64"
    reference = "spiritlhl/pve:" + tag
    if (str(metadata.get("pve_major")), metadata.get("architecture"), metadata.get("image")) != (major, arch, reference):
        raise ValueError("Release version, architecture or source image does not match")
    checks = metadata.get("validation", {})
    if not all(checks.get(key) is True for key in
               ("https_pam", "container_restart", "password_change_persistent", "host_units_masked")):
        raise ValueError("Release is missing successful runtime checks")
    if checks.get("qm_boot_reboot") != "tcg":
        raise ValueError("Release guest boot/reboot check is absent")
    if arch == "arm64" and metadata.get("validation_environment") != "independent-github-hosted-arm64-vm":
        raise ValueError("ARM64 Release lacks independent native runtime validation")
    image_id = metadata.get("image_id", "")
    if not DIGEST.fullmatch(image_id):
        raise ValueError("Invalid validated image ID")
    entries = [item for item in metadata.get("dockerhub", []) if item.get("reference") == reference]
    if len(entries) != 1:
        raise ValueError("Release must identify one Docker Hub source manifest")
    entry = entries[0]
    digest = entry.get("digest", "")
    if (not DIGEST.fullmatch(digest) or entry.get("image_id") != image_id
            or entry.get("architecture") != arch):
        raise ValueError("Release Docker Hub digest, image ID or architecture is inconsistent")
    tags = [major, major + "_x86_64"] if arch == "amd64" else [tag, major + "_arm64"]
    return {"source": "docker.io/spiritlhl/pve@" + digest, "digest": digest,
            "image_id": image_id, "architecture": arch, "tags": tags}


def inspect(reference, target):
    raw = subprocess.check_output(["skopeo", "inspect", "--retry-times", "4", "--raw", "docker://" + reference])
    if "sha256:" + hashlib.sha256(raw).hexdigest() != target["digest"]:
        raise ValueError("Manifest digest differs from validated Release: " + reference)
    manifest = json.loads(raw)
    if manifest.get("config", {}).get("digest") != target["image_id"]:
        raise ValueError("Image ID differs from validated Release: " + reference)
    config = json.loads(subprocess.check_output(
        ["skopeo", "inspect", "--retry-times", "4", "--config", "docker://" + reference]))
    if (config.get("os"), config.get("architecture")) != ("linux", target["architecture"]):
        raise ValueError("Unexpected image platform: " + reference)


def unchanged(reference, target):
    result = subprocess.run(["skopeo", "inspect", "--retry-times", "4", "--raw", "docker://" + reference],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.returncode == 0 and "sha256:" + hashlib.sha256(result.stdout).hexdigest() == target["digest"]


def main():
    # Check every source before changing any destination tag. A failed or
    # incomplete upstream publication must not become a new CNB image.
    targets = [validated_target(download_metadata(major, arch), major, arch)
               for major, arch in TARGETS]
    for target in targets:
        inspect(target["source"], target)
    for target in targets:
        if all(unchanged(DESTINATION + ":" + tag, target) for tag in target["tags"]):
            print("Unchanged: " + ", ".join(DESTINATION + ":" + tag for tag in target["tags"]), flush=True)
            continue
        for tag in target["tags"]:
            destination = DESTINATION + ":" + tag
            subprocess.run(["skopeo", "copy", "--retry-times", "4", "--preserve-digests",
                            "docker://" + target["source"], "docker://" + destination], check=True)
            inspect(destination, target)
        destination = DESTINATION + ":" + target["tags"][0]
        subprocess.run(["docker", "pull", "--platform=linux/" + target["architecture"], destination], check=True)
        actual = json.loads(subprocess.check_output(["docker", "image", "inspect", destination]))[0]
        if (actual["Id"], actual["Os"], actual["Architecture"]) != (target["image_id"], "linux", target["architecture"]):
            raise ValueError("Docker pull did not return the validated image: " + destination)
        print(json.dumps({"image": destination, "tags": target["tags"], "digest": target["digest"],
                          "image_id": target["image_id"], "architecture": target["architecture"],
                          "docker_pull_verified": True}), flush=True)


if __name__ == "__main__":
    main()
