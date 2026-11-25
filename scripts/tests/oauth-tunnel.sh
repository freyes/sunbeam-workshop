#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for scripts/oauth-tunnel.sh - the `just connect NAME` /
# `just disconnect NAME` behavior. The REAL oauth-tunnel.sh runs against a
# stub `workshop` binary on PATH that logs every call and answers per the
# WORKSHOP_* fixture knobs, so every contract path (wire the pair, idempotent
# skip both ways, unlaunched refusal, refusal propagation, usage/name
# validation) is exercised without touching the host or a live LXD.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
TUNNEL="${PROJECT_DIR}/scripts/oauth-tunnel.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# All fixture roots live under one suite tmp dir so the EXIT trap cleans up
# even when a test subshell fails mid-way.
SUITE_TMP=$(mktemp -d /tmp/sunbeam-oauth-tunnel-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

new_root() {
    mktemp -d "${SUITE_TMP}/root.XXXXXX"
}

# Fixture tree: empty root with a stub `workshop` on bin/. The stub logs
# every call and answers per the fixture knobs:
#   WORKSHOP_INFO_MODE      ok | missing  (`workshop info NAME` answers or refuses)
#   WORKSHOP_TUNNEL_ROW     connected | absent  (the tunnel row in `connections`)
#   WORKSHOP_CONNECT_MODE   ok | refuse  (`workshop connect` succeeds or refuses)
make_fixture() {
    local root=$1
    mkdir -p "${root}/bin"
    cat > "${root}/bin/workshop" <<'EOF'
#!/usr/bin/env bash
# workshop stub: log every call; answer per the WORKSHOP_* fixture knobs.
echo "workshop $*" >> "${WORKSHOP_LOG:?}"
cmd="${1:-}"
shift || true
case "$cmd" in
    info)
        case "${WORKSHOP_INFO_MODE:-ok}" in
            ok) : ;;
            missing)
                echo "error: workshop \"${1:-}\" not launched" >&2
                exit 1
                ;;
        esac
        ;;
    connections)
        printf 'INTERFACE\tPLUG\tSLOT\tNOTES\n'
        if [ "${WORKSHOP_TUNNEL_ROW:-absent}" = "connected" ]; then
            printf 'tunnel\t%s/system:mcp-oauth-callback\t%s/opencode:opencode-mcp-oauth-callback\tmanual\n' \
                "${1:-}" "${1:-}"
        fi
        ;;
    connect)
        case "${WORKSHOP_CONNECT_MODE:-ok}" in
            ok) echo "connected ${1:-} to ${2:-}" ;;
            refuse)
                echo "error: cannot resolve connection: SDK has no plug named mcp-oauth-callback" >&2
                exit 1
                ;;
        esac
        ;;
    disconnect)
        echo "disconnected ${1:-} from ${2:-}"
        ;;
    *)
        echo "workshop stub: unhandled command '${cmd}'" >&2
        exit 64
        ;;
esac
EOF
    chmod +x "${root}/bin/workshop"
}

run_tunnel() {
    local root=$1 verb=$2 name=$3
    env PATH="${root}/bin:${PATH}" \
        WORKSHOP_LOG="${root}/workshop.log" \
        bash "${TUNNEL}" "${verb}" "${name}"
}

test_connect_wires_the_pair() (
    local root output
    root=$(new_root); make_fixture "$root"
    output=$(run_tunnel "$root" connect fixture) || fail "connect failed: ${output}"
    grep -qF "workshop connect fixture/system:mcp-oauth-callback fixture/opencode:opencode-mcp-oauth-callback" \
        "${root}/workshop.log" || fail "wrong pair connected: $(cat "${root}/workshop.log")"
    grep -q "Connected fixture/system:mcp-oauth-callback to fixture/opencode:opencode-mcp-oauth-callback" \
        <<<"${output}" || fail "no success report: ${output}"
)

test_connect_skips_existing_row() (
    local root output
    root=$(new_root); make_fixture "$root"
    output=$(WORKSHOP_TUNNEL_ROW=connected run_tunnel "$root" connect fixture) \
        || fail "already-connected connect failed: ${output}"
    grep -q "already connected" <<<"${output}" \
        || fail "no already-connected note: ${output}"
    if grep -qE '^workshop connect ' "${root}/workshop.log"; then
        fail "connect re-attempted despite the existing row: $(cat "${root}/workshop.log")"
    fi
)

test_connect_refuses_unlaunched() (
    local root output status
    root=$(new_root); make_fixture "$root"
    output=$(WORKSHOP_INFO_MODE=missing run_tunnel "$root" connect fixture 2>&1) && status=0 || status=$?
    [ "$status" -eq 1 ] || fail "unlaunched connect exit code was ${status}, want 1: ${output}"
    grep -q "not launched" <<<"${output}" || fail "refusal reason missing: ${output}"
    if grep -qE '^workshop connect ' "${root}/workshop.log"; then
        fail "connect attempted on an unlaunched instance: $(cat "${root}/workshop.log")"
    fi
)

test_connect_refusal_propagates() (
    local root output status
    root=$(new_root); make_fixture "$root"
    output=$(WORKSHOP_CONNECT_MODE=refuse run_tunnel "$root" connect fixture 2>&1) && status=0 || status=$?
    [ "$status" -eq 1 ] || fail "refused connect exit code was ${status}, want 1: ${output}"
    grep -q "cannot resolve connection" <<<"${output}" \
        || fail "refusal output was swallowed: ${output}"
)

test_disconnect_unwires_the_pair() (
    local root output
    root=$(new_root); make_fixture "$root"
    output=$(WORKSHOP_TUNNEL_ROW=connected run_tunnel "$root" disconnect fixture) \
        || fail "disconnect failed: ${output}"
    grep -qF "workshop disconnect fixture/system:mcp-oauth-callback fixture/opencode:opencode-mcp-oauth-callback" \
        "${root}/workshop.log" || fail "wrong pair disconnected: $(cat "${root}/workshop.log")"
    grep -q "Disconnected fixture/system:mcp-oauth-callback from fixture/opencode:opencode-mcp-oauth-callback" \
        <<<"${output}" || fail "no success report: ${output}"
)

test_disconnect_skips_absent_row() (
    local root output
    root=$(new_root); make_fixture "$root"
    output=$(run_tunnel "$root" disconnect fixture) || fail "absent-row disconnect failed: ${output}"
    grep -q "nothing to do" <<<"${output}" || fail "no nothing-to-do note: ${output}"
    if grep -qE '^workshop disconnect ' "${root}/workshop.log"; then
        fail "disconnect attempted despite the absent row: $(cat "${root}/workshop.log")"
    fi
)

test_usage_and_name_errors_never_call_workshop() (
    local root output status
    root=$(new_root); make_fixture "$root"
    # No arguments.
    output=$(env PATH="${root}/bin:${PATH}" bash "${TUNNEL}" 2>&1) && status=0 || status=$?
    [ "$status" -eq 2 ] || fail "no-args exit code was ${status}, want 2: ${output}"
    # Unknown verb.
    output=$(env PATH="${root}/bin:${PATH}" bash "${TUNNEL}" unwire fixture 2>&1) && status=0 || status=$?
    [ "$status" -eq 2 ] || fail "unknown-verb exit code was ${status}, want 2: ${output}"
    # Invalid names: uppercase, underscore, 41 chars.
    for bad in Fixture fix_ure "$(printf 'a%.0s' {1..41})"; do
        output=$(env PATH="${root}/bin:${PATH}" bash "${TUNNEL}" connect "$bad" 2>&1) && status=0 || status=$?
        [ "$status" -eq 2 ] || fail "invalid name '$bad' exit code was ${status}, want 2: ${output}"
    done
    [ ! -f "${root}/workshop.log" ] \
        || fail "workshop was called for a usage/name error: $(cat "${root}/workshop.log")"
    # Help prints usage and exits 0.
    output=$(env PATH="${root}/bin:${PATH}" bash "${TUNNEL}" --help 2>&1) || fail "--help failed: ${output}"
    grep -q "Usage: bash scripts/oauth-tunnel.sh" <<<"${output}" \
        || fail "--help printed no usage: ${output}"
)

test_connect_wires_the_pair
test_connect_skips_existing_row
test_connect_refuses_unlaunched
test_connect_refusal_propagates
test_disconnect_unwires_the_pair
test_disconnect_skips_absent_row
test_usage_and_name_errors_never_call_workshop
echo "oauth-tunnel tests passed."