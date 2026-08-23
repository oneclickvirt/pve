#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${repo_root}/extra_scripts/install_ifupdown2.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "$fake_bin"
systemctl_log="${tmp_dir}/systemctl.log"
apt_log="${tmp_dir}/apt.log"

cat >"${fake_bin}/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$IFUPDOWN2_TEST_APT_LOG"
exit "${IFUPDOWN2_TEST_APT_EXIT:-0}"
EOF
cat >"${fake_bin}/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$IFUPDOWN2_TEST_SYSTEMCTL_LOG"
exit 0
EOF
chmod 755 "${fake_bin}/apt-get" "${fake_bin}/systemctl"

assert_file() {
    local path="$1"
    local label="$2"
    if [[ ! -e "$path" ]]; then
        printf 'FAIL: %s: missing %s\n' "$label" "$path" >&2
        exit 1
    fi
}

assert_absent() {
    local path="$1"
    local label="$2"
    if [[ -e "$path" ]]; then
        printf 'FAIL: %s: unexpected %s\n' "$label" "$path" >&2
        exit 1
    fi
}

run_installer_copy() {
    local destination="$1"
    cp "$installer" "$destination"
    chmod 755 "$destination"
    PATH="${fake_bin}:$PATH" \
        IFUPDOWN2_MARKER_FILE="${tmp_dir}/marker" \
        IFUPDOWN2_UNIT_FILE="${tmp_dir}/ifupdown2-install.service" \
        IFUPDOWN2_SERVICE_NAME="ifupdown2-install.service" \
        IFUPDOWN2_TEST_APT_LOG="$apt_log" \
        IFUPDOWN2_TEST_SYSTEMCTL_LOG="$systemctl_log" \
        IFUPDOWN2_TEST_APT_EXIT="${IFUPDOWN2_TEST_APT_EXIT:-0}" \
        "$destination"
}

printf '1\n' >"${tmp_dir}/ifupdown2-install.service"
IFUPDOWN2_TEST_APT_EXIT=0 run_installer_copy "${tmp_dir}/install-success.sh"
assert_file "${tmp_dir}/marker" "successful install marker"
[[ "$(cat "${tmp_dir}/marker")" == "1" ]] || {
    printf 'FAIL: successful install marker has unexpected content\n' >&2
    exit 1
}
assert_absent "${tmp_dir}/ifupdown2-install.service" "successful service cleanup"
assert_absent "${tmp_dir}/install-success.sh" "successful self cleanup"
grep -Fq 'ifupdown2' "$apt_log"
grep -Fq 'disable ifupdown2-install.service' "$systemctl_log"
grep -Fq 'daemon-reload' "$systemctl_log"

# Start the failure case without the marker produced by the successful run.
rm -f -- "${tmp_dir}/marker"
printf '1\n' >"${tmp_dir}/ifupdown2-install.service"
set +e
IFUPDOWN2_TEST_APT_EXIT=42 run_installer_copy "${tmp_dir}/install-failure.sh"
failure_status=$?
set -e
if [[ "$failure_status" -eq 0 ]]; then
    printf 'FAIL: apt failure was accepted by install_ifupdown2.sh\n' >&2
    exit 1
fi
assert_absent "${tmp_dir}/marker" "failed install marker"
assert_file "${tmp_dir}/ifupdown2-install.service" "failed install service preservation"
assert_file "${tmp_dir}/install-failure.sh" "failed install self preservation"

printf 'ifupdown2 installer lifecycle tests passed\n'
