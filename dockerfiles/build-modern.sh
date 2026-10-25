#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$BASH_SOURCE")/.." && pwd)
major=${1:-9}
case "$major" in
  7) debian=bullseye ;;
  8) debian=bookworm ;;
  9) debian=trixie ;;
  *) echo 'Use PVE major version 7, 8 or 9' >&2; exit 1 ;;
esac
publish=${PUBLISH_RELEASE:-false}
publish_hub=${PUBLISH_DOCKERHUB:-false}
[[ "$publish" == true || "$publish" == false ]] || { echo 'Invalid publication mode' >&2; exit 1; }
[[ "$publish_hub" == true || "$publish_hub" == false ]] || { echo 'Invalid Docker Hub publication mode' >&2; exit 1; }
if [[ "$publish" == true && -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  echo 'GitHub Release publication requires a configured release credential' >&2
  exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/pve-docker-build.XXXXXXXX")
key=$(basename "$work" | tr '[:upper:]' '[:lower:]')
image="oneclickvirt-pve-$key:$major"
validator="oneclickvirt-pve-validator-$key:latest"
container="pve-validator-$key"
release_images=()
previous_image_ids=()
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  for index in "${!release_images[@]}"; do
    if [[ -n "${previous_image_ids[$index]:-}" ]]; then
      docker tag "${previous_image_ids[$index]}" "${release_images[$index]}" >/dev/null 2>&1 || true
    else
      docker image rm "${release_images[$index]}" >/dev/null 2>&1 || true
    fi
  done
  docker image rm "$validator" "$image" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

source_sha=$(git -C "$ROOT_DIR" rev-parse HEAD)
printf 'Building experimental PVE %s on Debian %s; source=%s\n' "$major" "$debian" "$source_sha"
docker build --platform linux/amd64 --pull \
  --build-arg DEBIAN_RELEASE="$debian" --build-arg PVE_MAJOR="$major" \
  -t "$image" -f "$ROOT_DIR/dockerfiles/Dockerfile" "$ROOT_DIR/dockerfiles"
version=$(docker run --rm --entrypoint dpkg-query "$image" -W '-f=${Version}' pve-manager)
[[ "$version" == "$major".* ]] || { echo 'Unexpected PVE package version' >&2; exit 1; }
docker save "$image" -o "$work/image.tar"

# Use the independently maintained test guest, and verify GitHub's asset digest.
python3 - "$work/guest.qcow2" <<'PY'
import hashlib,json,sys,urllib.request
from pathlib import Path
url='https://api.github.com/repos/oneclickvirt/pve_kvm_images/releases/tags/alpine'
with urllib.request.urlopen(urllib.request.Request(url,headers={'Accept':'application/vnd.github+json','User-Agent':'oneclickvirt-pve-validation'}),timeout=90) as response:
    release=json.load(response)
matches=[asset for asset in release['assets'] if asset['name']=='alpine3.22.qcow2']
if len(matches)!=1 or not matches[0].get('digest','').startswith('sha256:'):
    raise RuntimeError('Missing verifiable runtime test guest')
asset=matches[0];path=Path(sys.argv[1]);digest=hashlib.sha256()
with urllib.request.urlopen(asset['browser_download_url'],timeout=600) as response,path.open('wb') as target:
    for block in iter(lambda:response.read(1024*1024),b''):
        target.write(block);digest.update(block)
if path.stat().st_size!=asset['size'] or 'sha256:'+digest.hexdigest()!=asset['digest']:
    raise RuntimeError('Runtime test guest checksum mismatch')
path.with_suffix('.json').write_text(json.dumps({'id':asset['id'],'name':asset['name'],'sha256':digest.hexdigest()},indent=2)+'\n')
PY

docker build --pull -t "$validator" -f "$ROOT_DIR/dockerfiles/runtime-vm.Dockerfile" "$ROOT_DIR"
# CNB's Docker daemon uses a separate filesystem. Copy explicit inputs instead
# of binding paths from the publisher's filesystem into the Docker service.
# No privileged flag, host network, Docker socket or credentials enter the
# launcher. Privileged PVE runs only inside its disposable QEMU VM.
validator_devices=()
if [[ -c /dev/kvm ]]; then
  validator_devices+=(--device /dev/kvm)
fi
docker create --name "$container" "${validator_devices[@]}" "$validator" "$major" "$image" >/dev/null
docker cp "$work/image.tar" "$container:/input/image.tar"
docker cp "$work/guest.qcow2" "$container:/input/guest.qcow2"
docker start -a "$container" | tee "$work/validation.log"
[[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" == 0 ]] || {
  echo 'Isolated PVE runtime validation failed; previous Release retained' >&2
  exit 1
}
grep -q "PVE_DOCKER_ISOLATED_VERIFICATION_COMPLETE major=$major" "$work/validation.log"

image_id=$(docker image inspect --format '{{.Id}}' "$image")
for reference in "spiritlhl/pve:$major" "spiritlhl/pve:${major}_x86_64" "oneclickvirt/pve:$major"; do
  previous_image_ids+=("$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null || true)")
  release_images+=("$reference")
  docker tag "$image" "$reference"
done
if [[ "$publish_hub" == true ]]; then
  docker push "spiritlhl/pve:$major"
  docker push "spiritlhl/pve:${major}_x86_64"
  python3 "$ROOT_DIR/dockerfiles/verify-hub.py" "$image_id" "$work/dockerhub.json" \
    "spiritlhl/pve:$major" "spiritlhl/pve:${major}_x86_64"
fi
docker save "${release_images[@]}" | gzip -1 > "$work/pve${major}-amd64.tar.gz"
python3 - "$work" "$major" "$version" "$source_sha" "$image_id" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);major,version,source=sys.argv[2:]
image=root/f'pve{major}-amd64.tar.gz'
with image.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
(root/'SHA256SUMS').write_text(digest+'  '+image.name+'\n')
(root/'build.json').write_text(json.dumps({'pve_major':major,'pve_version':version,'source_sha':source,
    'architecture':'amd64','image':'spiritlhl/pve:'+major,
    'image_aliases':['spiritlhl/pve:'+major+'_x86_64','oneclickvirt/pve:'+major],
    'image_id':sys.argv[5],
    'dockerhub':json.loads((root/'dockerhub.json').read_text()) if (root/'dockerhub.json').is_file() else [],
    'archive':image.name,'size':image.stat().st_size,
    'sha256':digest,'validation':{'https_pam':True,'qm_boot_reboot':'tcg','container_restart':True,
    'password_change_persistent':True,'host_units_masked':True},'test_guest':json.loads((root/'guest.json').read_text())},indent=2)+'\n')
PY
if [[ "$publish" == true ]]; then
  export GH_TOKEN=${GH_TOKEN:-$GITHUB_TOKEN}
  export GITHUB_REPOSITORY=oneclickvirt/pve GITHUB_SHA="$source_sha"
  python3 "$ROOT_DIR/dockerfiles/release_assets.py" "docker-pve$major" \
    "$work/pve${major}-amd64.tar.gz" "$work/SHA256SUMS" "$work/build.json"
  echo "PVE $major runtime checks and verified GitHub Release publication completed"
else
  echo "PVE $major build and isolated runtime checks passed; publication disabled"
fi
