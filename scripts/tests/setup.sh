#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for scripts/setup.sh - the guided 6-step setup walkthrough.
# The REAL setup.sh runs from a fixture tree: stub doctor/render/secret-setup
# scripts sit beside it, and stub `workshop`/`uv` binaries go on PATH, so the
# pre-launch status case and the final hints are exercised without touching
# the host. The uv shim runs the real sunbeam_workshop module with the system
# python (PYTHONPATH), exactly like the render.sh suite's fixture pattern.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
SETUP="${PROJECT_DIR}/scripts/setup.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# All fixture roots live under one suite tmp dir so the EXIT trap cleans up
# even when a test subshell fails mid-way.
SUITE_TMP=$(mktemp -d /tmp/sunbeam-setup-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

new_root() {
    mktemp -d "${SUITE_TMP}/root.XXXXXX"
}

# Fixture tree: the real setup.sh + stub step scripts under scripts/, empty
# profiles/ and config/ dirs (tests add profile dirs), and stub binaries.
make_fixture() {
    local root=$1 step
    mkdir -p "${root}/scripts" "${root}/profiles" "${root}/config" "${root}/bin"
    cp "${SETUP}" "${root}/scripts/setup.sh"
    for step in doctor.sh render.sh secret-setup.sh; do
        printf '#!/usr/bin/env bash\necho "stub %s $*"\n' "${step}" \
            > "${root}/scripts/${step}"
        chmod +x "${root}/scripts/${step}"
    done
    cat > "${root}/bin/workshop" <<'EOF'
#!/usr/bin/env bash
# workshop stub: log every call; info prints the canned status.
echo "workshop $*" >> "$WORKSHOP_LOG"
if [ "${1:-}" = "info" ]; then
    printf 'name: %s\nstatus: %s\n' "${2:-unknown}" "${WORKSHOP_STATUS:-Ready}"
fi
EOF
    chmod +x "${root}/bin/workshop"
    cat > "${root}/bin/uv" <<EOF
#!/usr/bin/env bash
# uv shim: run the real module with the system python, as uv run would.
if [ "\$1" = "run" ]; then
    shift
    while [ "\${1:-}" = "--frozen" ]; do shift; done
    [ "\${1:-}" = "python" ] && shift
    exec env PYTHONPATH="${PROJECT_DIR}/scripts" python3 "\$@"
fi
echo "uv shim: unsupported invocation: \$*" >&2
exit 1
EOF
    chmod +x "${root}/bin/uv"
}

run_setup() {
    local root=$1 name=$2
    env PATH="${root}/bin:${PATH}" \
        WORKSHOP_LOG="${root}/workshop.log" \
        SETUP_YES=1 \
        bash "${root}/scripts/setup.sh" "${name}"
}

test_quoted_ready_status_takes_ready_path() (
    local root output
    root=$(new_root); make_fixture "${root}"
    mkdir -p "${root}/profiles/fixture"
    output=$(WORKSHOP_STATUS='"Ready"' run_setup "${root}" fixture) \
        || fail "setup with quoted Ready status failed: ${output}"
    grep -q "already active. Skipping launch." <<<"${output}" \
        || fail "quoted Ready status did not take the Ready path: ${output}"
    if [ -f "${root}/workshop.log" ] \
        && grep -qE 'workshop (launch|start)' "${root}/workshop.log"; then
        fail "quoted Ready status still launched/started: $(cat "${root}/workshop.log")"
    fi
)

test_repos_hint_resolves_dashed_profile() (
    local root output
    root=$(new_root); make_fixture "${root}"
    # Dashed profile: foo-bar-baz resolves to foo-bar by longest prefix;
    # first-dash truncation would hint the wrong `just repos foo`.
    mkdir -p "${root}/profiles/foo-bar"
    output=$(run_setup "${root}" foo-bar-baz) \
        || fail "setup of dashed-profile instance failed: ${output}"
    grep -qx '  just repos foo-bar    clone/update its repositories' <<<"${output}" \
        || fail "repos hint did not resolve the dashed profile: ${output}"
    if grep -q 'just repos foo ' <<<"${output}"; then
        fail "repos hint used first-dash truncation: ${output}"
    fi
)

test_quoted_ready_status_takes_ready_path
test_repos_hint_resolves_dashed_profile
echo "setup tests passed."
