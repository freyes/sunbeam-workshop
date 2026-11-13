#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Test suite for scripts/doctor.sh: every command the doctor probes is
# replaced by a stub in a mktemp fixture, so runs are hermetic and
# deterministic (awesome-multirepo scripts/tests pattern: fail helper,
# mktemp fixtures; cleanup via trap).

set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
DOCTOR="${PROJECT_DIR}/scripts/doctor.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Coreutils the doctor legitimately needs; everything else comes from stubs.
SAFE_PATH="/usr/bin:/bin"

LAST_OUT=""
LAST_RC=0

# run_doctor STUBBIN HOME [ARGS...] - captures combined output and rc.
run_doctor() {
    local stubbin=$1 home=$2
    shift 2
    set +e
    LAST_OUT=$(env PATH="${stubbin}:${SAFE_PATH}" HOME="${home}" bash "${DOCTOR}" "$@" 2>&1)
    LAST_RC=$?
    set -e
}

# A fully green fixture: every probed command exists and succeeds, the LXD
# server reports the given version, gh is authenticated, sdk lists one SDK.
make_stubbin() {
    local dir=$1 lxd_version=$2
    mkdir -p "${dir}"
    cat > "${dir}/workshop" <<'EOF'
#!/bin/sh
[ "${1:-}" = "--version" ] && printf 'workshop 0.0.0-test\n'
exit 0
EOF
    cat > "${dir}/lxc" <<EOF
#!/bin/sh
printf 'Client version: %s\nServer version: %s\n' '${lxd_version}' '${lxd_version}'
EOF
    local tool
    for tool in just uv git jq yq; do
        printf '#!/bin/sh\nexit 0\n' > "${dir}/${tool}"
    done
    # Probe lookup: no entry, no error, rc 0.
    printf '#!/bin/sh\nexit 0\n' > "${dir}/secret-tool"
    printf '#!/bin/sh\nexit 0\n' > "${dir}/gh"
    cat > "${dir}/sdk" <<'EOF'
#!/bin/sh
printf 'opencode latest/edge 42\n'
EOF
    chmod +x "${dir}"/*
}

make_home() {
    local dir=$1 with_key=$2
    mkdir -p "${dir}"
    if [ "${with_key}" = "yes" ]; then
        mkdir -p "${dir}/.ssh"
        touch "${dir}/.ssh/id_ed25519.pub"
    fi
}

tests=0
ok() {
    tests=$((tests + 1))
    printf 'ok %s\n' "$1"
}

test_lxd_68_passes() {
    local bin="${WORK}/t-lxd68/bin" home="${WORK}/t-lxd68/home"
    make_stubbin "${bin}" 6.8
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 0 ] || fail "lxd 6.8: expected rc 0, got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '✓ LXD server 6.8 (Workshop requires >= 6.8)' \
        || fail "lxd 6.8: missing pass line: ${LAST_OUT}"
    ok "lxd 6.8 passes"
}

test_lxd_67_fails() {
    local bin="${WORK}/t-lxd67/bin" home="${WORK}/t-lxd67/home"
    make_stubbin "${bin}" 6.7
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 1 ] || fail "lxd 6.7: expected rc 1, got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '✗ LXD server 6.7 is older than 6.8, which Workshop requires' \
        || fail "lxd 6.7: missing fail line: ${LAST_OUT}"
    ok "lxd 6.7 fails"
}

test_green_host_exit_zero() {
    local bin="${WORK}/t-green/bin" home="${WORK}/t-green/home"
    make_stubbin "${bin}" 6.8
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 0 ] || fail "green host: expected rc 0, got ${LAST_RC}: ${LAST_OUT}"
    local line
    for line in \
        '✓ workshop installed (workshop 0.0.0-test)' \
        '✓ just on PATH' \
        '✓ uv on PATH' \
        '✓ git on PATH' \
        '✓ jq on PATH' \
        '✓ yq on PATH' \
        '✓ secret-tool can query the secret service' \
        '✓ host arch amd64 (supported, A-15)' \
        '✓ gh is authenticated on the host' \
        '✓ ssh public key(s) present under ~/.ssh'; do
        printf '%s' "${LAST_OUT}" | grep -qF "${line}" \
            || fail "green host: missing '${line}': ${LAST_OUT}"
    done
    ok "green host exits 0 with all pass lines"
}

test_missing_workshop_hard_fails() {
    local bin="${WORK}/t-noworkshop/bin" home="${WORK}/t-noworkshop/home"
    make_stubbin "${bin}" 6.8
    rm "${bin}/workshop"
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 1 ] || fail "missing workshop: expected rc 1, got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '✗ workshop is not on PATH' \
        || fail "missing workshop: missing fail line: ${LAST_OUT}"
    ok "missing workshop hard-fails"
}

test_missing_lxc_hard_fails() {
    local bin="${WORK}/t-nolxc/bin" home="${WORK}/t-nolxc/home"
    make_stubbin "${bin}" 6.8
    rm "${bin}/lxc"
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 1 ] || fail "missing lxc: expected rc 1, got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '✗ lxc is not on PATH' \
        || fail "missing lxc: missing fail line: ${LAST_OUT}"
    ok "missing lxc hard-fails"
}

test_missing_tools_warn_only() {
    local bin="${WORK}/t-notools/bin" home="${WORK}/t-notools/home"
    make_stubbin "${bin}" 6.8
    rm "${bin}/yq" "${bin}/just"
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 0 ] || fail "missing tools: expected rc 0 (warn-only), got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '⚠ yq is not on PATH' \
        || fail "missing tools: missing warn line: ${LAST_OUT}"
    ok "missing just/yq warn but do not hard-fail"
}

test_secret_tool_probe_tolerates_empty() {
    local bin="${WORK}/t-secempty/bin" home="${WORK}/t-secempty/home"
    make_stubbin "${bin}" 6.8
    # rc 1 with no stderr = entry absent: tolerated, not an error.
    printf '#!/bin/sh\nexit 1\n' > "${bin}/secret-tool"
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 0 ] || fail "empty probe: expected rc 0, got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '✓ secret-tool usable (probe entry absent, which is tolerated)' \
        || fail "empty probe: missing pass line: ${LAST_OUT}"
    ok "secret-tool probe tolerates an absent entry"
}

test_secret_tool_error_warns() {
    local bin="${WORK}/t-secerr/bin" home="${WORK}/t-secerr/home"
    make_stubbin "${bin}" 6.8
    printf '#!/bin/sh\necho "secret-tool: Cannot autolaunch D-Bus session" >&2\nexit 1\n' > "${bin}/secret-tool"
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 0 ] || fail "probe error: expected rc 0 (warn-only), got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '⚠ secret-tool probe failed:' \
        || fail "probe error: missing warn line: ${LAST_OUT}"
    ok "secret-tool service error warns"
}

test_gh_auth_failure_warns_with_pointer() {
    local bin="${WORK}/t-ghfail/bin" home="${WORK}/t-ghfail/home"
    make_stubbin "${bin}" 6.8
    printf '#!/bin/sh\necho "You are not logged into any GitHub hosts." >&2\nexit 1\n' > "${bin}/gh"
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 0 ] || fail "gh failure: expected rc 0 (warn-only), got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '⚠ gh is not authenticated on the host' \
        || fail "gh failure: missing warn line: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF 'https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token' \
        || fail "gh failure: missing token how-to pointer: ${LAST_OUT}"
    ok "gh auth failure warns with the GitHub token how-to pointer"
}

test_missing_ssh_pubkeys_warns_with_pointers() {
    local bin="${WORK}/t-nossh/bin" home="${WORK}/t-nossh/home"
    make_stubbin "${bin}" 6.8
    make_home "${home}" no
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 0 ] || fail "no ssh keys: expected rc 0 (warn-only), got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '⚠ no ssh public key under ~/.ssh' \
        || fail "no ssh keys: missing warn line: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF 'docs.opendev.org/opendev/infra-manual/latest/gettingstarted.html' \
        || fail "no ssh keys: missing Gerrit pointer: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF 'help.launchpad.net/YourAccount/CreatingAnSSHKeyPair' \
        || fail "no ssh keys: missing Launchpad pointer: ${LAST_OUT}"
    ok "missing ssh pubkeys warn with Gerrit/Launchpad pointers"
}

test_prerequisite_pointers_always_printed() {
    local bin="${WORK}/t-ptrs/bin" home="${WORK}/t-ptrs/home"
    make_stubbin "${bin}" 6.8
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    printf '%s' "${LAST_OUT}" | grep -qF 'https://ubuntu.com/legal/contributors' \
        || fail "pointers: missing Ubuntu One/ICLA line: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF 'https://id.atlassian.com' \
        || fail "pointers: missing Atlassian line: ${LAST_OUT}"
    ok "Ubuntu One/ICLA and Atlassian pointers always printed"
}

test_sdk_revision_report() {
    local bin="${WORK}/t-sdk/bin" home="${WORK}/t-sdk/home"
    make_stubbin "${bin}" 6.8
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    printf '%s' "${LAST_OUT}" | grep -qF 'ℹ sdk: opencode latest/edge 42' \
        || fail "sdk report: missing revision line: ${LAST_OUT}"
    local bin2="${WORK}/t-sdk2/bin" home2="${WORK}/t-sdk2/home"
    make_stubbin "${bin2}" 6.8
    rm "${bin2}/sdk"
    make_home "${home2}" yes
    run_doctor "${bin2}" "${home2}"
    printf '%s' "${LAST_OUT}" | grep -qF "no 'sdk' command on PATH" \
        || fail "sdk report: missing skip note: ${LAST_OUT}"
    ok "sdk list reported when present, noted when absent"
}

test_sunbeam_capacity_is_warn_only() {
    local bin="${WORK}/t-sunbeam/bin" home="${WORK}/t-sunbeam/home"
    make_stubbin "${bin}" 6.8
    # Force two capacity checks to warn: 2 vCPU and 20 GiB free.
    printf '#!/bin/sh\necho 2\n' > "${bin}/nproc"
    printf '#!/bin/sh\nprintf " Avail\\n20G\\n"\n' > "${bin}/df"
    chmod +x "${bin}/nproc" "${bin}/df"
    make_home "${home}" yes
    run_doctor "${bin}" "${home}" sunbeam
    [ "${LAST_RC}" -eq 0 ] || fail "sunbeam capacity: expected rc 0 (warn-only), got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF 'Capacity for the sunbeam profile (warn-only, A-15):' \
        || fail "sunbeam capacity: missing section header: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '⚠ host has 2 vCPU but the sunbeam sidecar VM wants >= 8' \
        || fail "sunbeam capacity: missing vCPU warn: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '⚠ only 20GiB free on' \
        || fail "sunbeam capacity: missing disk warn: ${LAST_OUT}"
    ok "sunbeam capacity checks warn but never hard-fail"
}

test_other_profile_skips_capacity() {
    local bin="${WORK}/t-charmed/bin" home="${WORK}/t-charmed/home"
    make_stubbin "${bin}" 6.8
    make_home "${home}" yes
    run_doctor "${bin}" "${home}" charmed
    [ "${LAST_RC}" -eq 0 ] || fail "charmed: expected rc 0, got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '(profile: charmed)' \
        || fail "charmed: missing profile label: ${LAST_OUT}"
    case "${LAST_OUT}" in
        *"Capacity for the sunbeam profile"*)
            fail "charmed: capacity section must not run for other profiles" ;;
    esac
    ok "non-sunbeam argument runs base checks only"
}

test_arm64_arch_warns() {
    local bin="${WORK}/t-arm/bin" home="${WORK}/t-arm/home"
    make_stubbin "${bin}" 6.8
    printf '#!/bin/sh\necho aarch64\n' > "${bin}/uname"
    chmod +x "${bin}/uname"
    make_home "${home}" yes
    run_doctor "${bin}" "${home}"
    [ "${LAST_RC}" -eq 0 ] || fail "arm64: expected rc 0 (warn-only), got ${LAST_RC}: ${LAST_OUT}"
    printf '%s' "${LAST_OUT}" | grep -qF '⚠ host arch arm64 is best-effort only (A-15)' \
        || fail "arm64: missing warn line: ${LAST_OUT}"
    ok "arm64 arch warns (best-effort, A-15)"
}

test_no_install_or_secret_write_strings() {
    local bin="${WORK}/t-clean/bin" home="${WORK}/t-clean/home"
    make_stubbin "${bin}" 6.7
    rm "${bin}/workshop"
    printf '#!/bin/sh\nexit 1\n' > "${bin}/gh"
    make_home "${home}" no
    run_doctor "${bin}" "${home}" sunbeam
    case "${LAST_OUT}" in
        *"apt-get install"* | *"snap install"* | *"secret-tool store"*)
            fail "doctor output must never suggest installs or keyring writes: ${LAST_OUT}" ;;
    esac
    ok "output never suggests installs or keyring writes"
}

test_lxd_68_passes
test_lxd_67_fails
test_green_host_exit_zero
test_missing_workshop_hard_fails
test_missing_lxc_hard_fails
test_missing_tools_warn_only
test_secret_tool_probe_tolerates_empty
test_secret_tool_error_warns
test_gh_auth_failure_warns_with_pointer
test_missing_ssh_pubkeys_warns_with_pointers
test_prerequisite_pointers_always_printed
test_sdk_revision_report
test_sunbeam_capacity_is_warn_only
test_other_profile_skips_capacity
test_arm64_arch_warns
test_no_install_or_secret_write_strings

echo "PASS: all ${tests} doctor tests"
