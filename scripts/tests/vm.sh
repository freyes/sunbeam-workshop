#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for scripts/vm/{create,destroy}.sh (awesome-multirepo scripts/tests
# pattern). Destroy-path tests run against a FIXTURE root in mktemp, selected
# via SUNBEAM_WORKSHOP_ROOT, with lxc replaced by a stub that logs every call
# - the suite never touches the real config/vm.json, .state/, or a real LXD.
# The cloud-init render tests use the REAL template with a fixture vars doc.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
CREATE="${PROJECT_DIR}/scripts/vm/create.sh"
DESTROY="${PROJECT_DIR}/scripts/vm/destroy.sh"
TEMPLATE="${PROJECT_DIR}/scripts/vm/cloud-init.yaml.j2"
JINJA2="${PROJECT_DIR}/scripts/jinja2"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# All fixture roots live under one suite tmp dir so the EXIT trap cleans up
# even when a test subshell fails mid-way.
SUITE_TMP=$(mktemp -d /tmp/sunbeam-vm-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

new_root() {
    mktemp -d "${SUITE_TMP}/root.XXXXXX"
}

# Fixture root: just config/vm.json - the destroy path reads nothing else.
make_fixture_root() {
    local root=$1
    mkdir -p "${root}/config"
    cat > "${root}/config/vm.json" <<'EOF'
{"name": "sunbeam-dev-test", "image": "ubuntu:26.04", "cpu": 8, "memory": "16GiB", "disk": "100GiB", "pool": "default"}
EOF
}

# Recorded state as create.sh would have left it: keypair, marker, ip, token
# and a 64-hex trust fingerprint.
make_state() {
    local root=$1
    mkdir -p "${root}/.state/vm"
    printf 'fixture-private-key\n' > "${root}/.state/vm/id_ed25519"
    printf 'fixture-public-key\n' > "${root}/.state/vm/id_ed25519.pub"
    printf '10.87.0.42\n' > "${root}/.state/vm/ip"
    printf 'fixture-token\n' > "${root}/.state/vm/lxd-token"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "${root}/.state/vm/lxd-trust-fingerprint"
    printf 'keep-me\n' > "${root}/.state/vm/marker"
}

# Stub lxc: logs argv to LXC_STUB_LOG; the VM always exists (info rc 0), the
# trust store always reads back empty (revocation verifiable), delete works.
make_stub_lxc() {
    local dir=$1
    mkdir -p "${dir}"
    cat > "${dir}/lxc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${LXC_STUB_LOG:?}"
case "${1:-}" in
    info)
        exit 0
        ;;
    delete)
        exit 0
        ;;
    exec)
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
        [ $# -gt 0 ] && shift
        if [ "${1:-} ${2:-} ${3:-} ${4:-}" = "lxc config trust list" ]; then
            printf '[]\n'
        fi
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "${dir}/lxc"
}

# Coreutils the scripts legitimately need; lxc comes from the stub.
SAFE_PATH="/usr/bin:/bin"

LAST_OUT=""
LAST_RC=0

# run_destroy STUBBIN ROOT [ENV...] - captures combined output and rc.
run_destroy() {
    local stubbin=$1 root=$2 log
    shift 2
    log="${root}/lxc-stub.log"
    set +e
    LAST_OUT=$(env PATH="${stubbin}:${SAFE_PATH}" SUNBEAM_WORKSHOP_ROOT="${root}" \
        I_KNOW_WHAT_IM_DOING=1 LXC_STUB_LOG="${log}" "$@" bash "${DESTROY}" </dev/null 2>&1)
    LAST_RC=$?
    set -e
}

run_create() {
    local root=$1
    shift
    set +e
    LAST_OUT=$(env SUNBEAM_WORKSHOP_ROOT="${root}" "$@" bash "${CREATE}" </dev/null 2>&1)
    LAST_RC=$?
    set -e
}

test_destroy_refuses_without_keypair() (
    local root stubbin
    root=$(new_root); make_fixture_root "${root}"
    stubbin=$(mktemp -d "${SUITE_TMP}/stubbin.XXXXXX"); make_stub_lxc "${stubbin}"
    run_destroy "${stubbin}" "${root}" YES=1
    [[ ${LAST_RC} -ne 0 ]] || fail "destroy without a keypair exited 0: ${LAST_OUT}"
    grep -q 'no sidecar VM state' <<<"${LAST_OUT}" \
        || fail "destroy without a keypair lacks a clear message: ${LAST_OUT}"
    grep -q 'lxc delete -f' <<<"${LAST_OUT}" \
        || fail "message does not name the manual recovery: ${LAST_OUT}"
    [[ ! -e "${root}/.state" ]] || fail "refused destroy still wrote .state."
    [[ ! -s "${root}/lxc-stub.log" ]] || fail "refused destroy still called lxc: $(cat "${root}/lxc-stub.log")"
)

test_destroy_requires_confirmation() (
    local root stubbin
    root=$(new_root); make_fixture_root "${root}"; make_state "${root}"
    stubbin=$(mktemp -d "${SUITE_TMP}/stubbin.XXXXXX"); make_stub_lxc "${stubbin}"
    # YES unset and stdin not a TTY (</dev/null): must refuse, touch nothing.
    run_destroy "${stubbin}" "${root}"
    [[ ${LAST_RC} -ne 0 ]] || fail "unconfirmed destroy exited 0: ${LAST_OUT}"
    grep -q 'confirmation did not match' <<<"${LAST_OUT}" \
        || fail "unconfirmed destroy lacks a clear message: ${LAST_OUT}"
    [[ -f "${root}/.state/vm/marker" ]] || fail "unconfirmed destroy dropped .state contents."
    [[ ! -s "${root}/lxc-stub.log" ]] || fail "unconfirmed destroy still called lxc: $(cat "${root}/lxc-stub.log")"
)

test_destroy_happy_preserves_state() (
    local root stubbin log
    root=$(new_root); make_fixture_root "${root}"; make_state "${root}"
    stubbin=$(mktemp -d "${SUITE_TMP}/stubbin.XXXXXX"); make_stub_lxc "${stubbin}"
    log="${root}/lxc-stub.log"
    run_destroy "${stubbin}" "${root}" YES=1
    [[ ${LAST_RC} -eq 0 ]] || fail "happy destroy exited ${LAST_RC}: ${LAST_OUT}"
    # The VM is deleted and the trust revoked server-side before deletion.
    grep -q 'delete -f sunbeam-dev-test' "${log}" || fail "stub saw no delete: $(cat "${log}")"
    grep -q 'config trust remove' "${log}" || fail "stub saw no server-side revocation: $(cat "${log}")"
    # One-shot records are gone; keypair and anything else in .state/vm stay.
    [[ ! -e "${root}/.state/vm/lxd-token" ]] || fail "token left behind after destroy."
    [[ ! -e "${root}/.state/vm/lxd-trust-fingerprint" ]] || fail "fingerprint record left behind."
    [[ ! -e "${root}/.state/vm/ip" ]] || fail "ip record left behind."
    [[ -f "${root}/.state/vm/id_ed25519" ]] || fail "keypair not retained (PURGE unset)."
    [[ -f "${root}/.state/vm/marker" ]] || fail "PURGE unset did not preserve .state/vm contents."
    grep -q 'Keypair kept' <<<"${LAST_OUT}" || fail "output does not state the retention: ${LAST_OUT}"
)

test_destroy_purge_removes_state() (
    local root stubbin
    root=$(new_root); make_fixture_root "${root}"; make_state "${root}"
    stubbin=$(mktemp -d "${SUITE_TMP}/stubbin.XXXXXX"); make_stub_lxc "${stubbin}"
    run_destroy "${stubbin}" "${root}" YES=1 PURGE=1
    [[ ${LAST_RC} -eq 0 ]] || fail "PURGE destroy exited ${LAST_RC}: ${LAST_OUT}"
    [[ ! -d "${root}/.state/vm" ]] || fail "PURGE=1 kept .state/vm."
)

test_create_refuses_in_workshop_container() (
    local root
    root=$(new_root); make_fixture_root "${root}"
    # USER=workshop without the bypass: refuse before any state write.
    run_create "${root}" env -u I_KNOW_WHAT_IM_DOING -u GITHUB_ACTIONS USER=workshop
    [[ ${LAST_RC} -ne 0 ]] || fail "create as USER=workshop exited 0: ${LAST_OUT}"
    grep -q 'not inside the Workshop container' <<<"${LAST_OUT}" \
        || fail "container refusal message missing: ${LAST_OUT}"
    [[ ! -e "${root}/.state" ]] || fail "refused create still wrote .state."
)

test_create_refuses_on_github_actions() (
    local root
    root=$(new_root); make_fixture_root "${root}"
    # A runner (GITHUB_ACTIONS=true) without the bypass: refuse.
    run_create "${root}" env -u I_KNOW_WHAT_IM_DOING USER=runner GITHUB_ACTIONS=true
    [[ ${LAST_RC} -ne 0 ]] || fail "create on a GH runner exited 0: ${LAST_OUT}"
    grep -q 'GitHub Actions runner' <<<"${LAST_OUT}" \
        || fail "runner refusal message missing: ${LAST_OUT}"
    [[ ! -e "${root}/.state" ]] || fail "refused create still wrote .state."
)

# Fixture merged vars doc: the real sunbeam pins, plus the pubkey create.sh
# would inject. Kept hermetic (never reads the real profiles/ tree).
make_fixture_vars() {
    local path=$1
    cat > "${path}" <<'EOF'
{
  "workshop_name": "sunbeam",
  "profile": "sunbeam",
  "suffix": "",
  "shadow_warning": false,
  "profile_vars": {
    "snaps": {
      "snapcraft": {"channel": "latest/stable", "classic": true},
      "rockcraft": {"channel": "latest/stable", "classic": true},
      "charmcraft": {"channel": "latest/stable", "classic": true},
      "juju": {"channel": "3.6/stable"}
    },
    "k8s": {"snap": "microk8s", "channel": "1.32-classic/stable"}
  },
  "config": {},
  "user": {"name": "test", "github_handle": null, "email": null},
  "vm_pubkey": "ssh-ed25519 AAAAFixtureKey test@fixture"
}
EOF
}

test_cloud_init_render() (
    local vars out
    vars="${SUITE_TMP}/vars.json"; make_fixture_vars "${vars}"
    out="${SUITE_TMP}/cloud-init.yaml"
    "${JINJA2}" "${TEMPLATE}" "${vars}" > "${out}" || fail "cloud-init render failed."
    grep -q '^#cloud-config' "${out}" || fail "render is missing the #cloud-config header."
    grep -q 'name: dev' "${out}" || fail "render does not create the dev user."
    grep -q 'ssh-ed25519 AAAAFixtureKey test@fixture' "${out}" \
        || fail "injected pubkey did not flow into the render."
    grep -q 'snap install --classic --channel=latest/stable snapcraft' "${out}" \
        || fail "snapcraft classic install missing or wrong channel."
    grep -q 'snap install --classic --channel=latest/stable rockcraft' "${out}" \
        || fail "rockcraft classic install missing or wrong channel."
    grep -q 'snap install --classic --channel=latest/stable charmcraft' "${out}" \
        || fail "charmcraft classic install missing or wrong channel."
    grep -q 'snap install --classic --channel=1.32-classic/stable microk8s' "${out}" \
        || fail "microk8s install missing or wrong channel."
    grep -q 'snap install --channel=3.6/stable juju' "${out}" \
        || fail "juju install missing or wrong channel."
    grep -q '/var/lib/sunbeam-provisioned' "${out}" || fail "provisioning marker missing."
    if python3 -c 'import yaml' 2>/dev/null; then
        python3 - "${out}" <<'PY' || fail "yaml-level assertion failed (microk8s in snap.commands)."
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)
commands = doc.get("snap", {}).get("commands", [])
assert any("microk8s" in str(c) for c in commands), commands
PY
    fi
)

test_cloud_init_render_deterministic() (
    local vars
    vars="${SUITE_TMP}/vars.json"; make_fixture_vars "${vars}"
    "${JINJA2}" "${TEMPLATE}" "${vars}" > "${SUITE_TMP}/first.yaml" || fail "first render failed."
    "${JINJA2}" "${TEMPLATE}" "${vars}" > "${SUITE_TMP}/second.yaml" || fail "second render failed."
    cmp "${SUITE_TMP}/first.yaml" "${SUITE_TMP}/second.yaml" || fail "re-render is not byte-identical."
)

test_destroy_refuses_without_keypair
test_destroy_requires_confirmation
test_destroy_happy_preserves_state
test_destroy_purge_removes_state
test_create_refuses_in_workshop_container
test_create_refuses_on_github_actions
test_cloud_init_render
test_cloud_init_render_deterministic
echo "vm tests passed."
