#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source <(sed -n '/^download_required_file() {/,/^}/p' "$repo_root/scripts/install_pve.sh")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
target="$work/service"

# The loaded downloader calls this failure mock indirectly.
# shellcheck disable=SC2317
wget() {
    : >"$3"
    return 8
}
if download_required_file https://example.invalid "$target" 755; then
    echo 'FAIL: failed download was accepted' >&2
    exit 1
fi
[[ ! -e "$target" ]]
[[ -z "$(find "$work" -type f -name 'service.tmp.*' -print -quit)" ]]

wget() {
    printf '%s\n' downloaded >"$3"
}
download_required_file https://example.invalid "$target" 755
[[ "$(<"$target")" == downloaded ]]
# GNU stat -f prints filesystem data before failing on the BSD format. Keep
# failed-command output out of the successful permission assertion.
mode=$(stat -c '%a' "$target" 2>/dev/null) || mode=$(stat -f '%Lp' "$target")
[[ "$mode" == 755 ]]
printf '%s\n' 'PVE atomic auxiliary download test passed'
