#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for scripts/secret-setup.sh - the two-credential host flow: the
# optional OpenRouter keyring prompt, the gh-cli + openrouter plug wiring
# and the post-Ready opencode auth converger. The REAL secret-setup.sh runs
# from a fixture tree with stub binaries on PATH, so nothing touches the
# host keyring, a real gh login, or a live workshop instance:
#   secret-tool  backed by a plain-text fixture keyring file (store appends
#                a service=<secret> line, lookup prints the stored secret,
#                clear removes the entry)
#   gh           auth status reports an existing login (login is skipped)
#   workshop     logs every invocation to $WORKSHOP_LOG; info prints a
#                selectable status (or fails for the not-launched case);
#                connections prints a selectable REAL row - four
#                TAB-separated columns: secret, plug, slot, manual;
#                connect can refuse exactly the openrouter-key plug
#                (WORKSHOP_CONNECT_FAIL: the stale-definition instance)
#                and exec can fail (WORKSHOP_EXEC_FAIL: a locked keyring
#                or corrupt auth.json inside the instance) - the two
#                degrade paths the real flow must survive
#   uv           shim running the real sunbeam_workshop module with the
#                system python via PYTHONPATH, exactly like the setup suite
# The fixture also carries profiles/fixture/ + an empty config/ so the vars
# module resolves the instance's profile against the fixture root.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
SECRET_SETUP="${PROJECT_DIR}/scripts/secret-setup.sh"

GH_SERVICE="sunbeam-workshop-github-token"
OR_SERVICE="sunbeam-workshop-openrouter-key"
GH_SEED="gh-stub-token-abc123"
OR_KEY="or-stub-key-xyz789"
OR_KEYLINE="${OR_SERVICE}=${OR_KEY}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# All fixture roots live under one suite tmp dir so the EXIT trap cleans up
# even when a test subshell fails mid-way.
SUITE_TMP=$(mktemp -d /tmp/sunbeam-secret-setup-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

new_root() {
    mktemp -d "${SUITE_TMP}/root.XXXXXX"
}

# Fixture tree: the real secret-setup.sh under scripts/, a fixture profile
# (profiles/fixture) + empty config/ for the vars module, and the stubs.
make_fixture() {
    local root=$1
    mkdir -p "${root}/scripts" "${root}/bin" "${root}/profiles/fixture" "${root}/config"
    cp "${SECRET_SETUP}" "${root}/scripts/secret-setup.sh"
    # Pre-seeded GitHub entry: the GitHub block reports already-stored, so
    # only the OpenRouter prompt reads stdin in the tests below.
    printf '%s\n' "${GH_SERVICE}=${GH_SEED}" > "${root}/keyring"
    cat > "${root}/bin/secret-tool" <<'EOF'
#!/usr/bin/env bash
# secret-tool stub: plain-text fixture keyring, one service=<secret> line
# per stored item; the secret arrives on stdin, never in argv.
keyring="${SECRET_TOOL_KEYRING:?secret-tool stub: SECRET_TOOL_KEYRING not set}"
cmd="${1:-}"
[ "$#" -gt 0 ] && shift
service=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "service" ] && [ "$#" -gt 1 ]; then
        service="$2"
        break
    fi
    shift
done
case "$cmd" in
    lookup)
        line="$(grep -m1 -- "^${service}=" "$keyring" 2>/dev/null)" || exit 1
        printf '%s\n' "${line#*=}"
        ;;
    store)
        secret="$(cat)"
        printf '%s=%s\n' "$service" "$secret" >> "$keyring"
        ;;
    clear)
        grep -v -- "^${service}=" "$keyring" > "$keyring.tmp" 2>/dev/null || true
        mv -f -- "$keyring.tmp" "$keyring"
        ;;
    *)
        echo "secret-tool stub: unsupported invocation: $cmd $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${root}/bin/secret-tool"
    cat > "${root}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub: auth status reports an existing login (the login path is
# skipped); auth login still consumes the piped token like the real gh.
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
    exit 0
fi
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "login" ]; then
    cat > /dev/null
    exit 0
fi
echo "gh stub: unsupported invocation: $*" >&2
exit 1
EOF
    chmod +x "${root}/bin/gh"
    cat > "${root}/bin/workshop" <<'EOF'
#!/usr/bin/env bash
# workshop stub: log every call; info prints a selectable status (or fails
# for the not-launched case); connections prints a selectable real row.
echo "workshop $*" >> "${WORKSHOP_LOG:?workshop stub: WORKSHOP_LOG not set}"
case "${1:-}" in
    info)
        if [ "${WORKSHOP_INFO_FAIL:-0}" = "1" ]; then
            echo "Error: instance '${2:-}' was not found (not launched)." >&2
            exit 1
        fi
        printf 'name: %s\nstatus: %s\n' "${2:-unknown}" "${WORKSHOP_STATUS:-Ready}"
        ;;
    connections)
        # A REAL row is four TAB-separated columns ending in a NOTES value
        # (manual). EPIPE from a -q grep reader is silenced so the exit
        # status stays the stub's own, not the pipe's.
        if [ -n "${CONNECTIONS_ROW:-}" ]; then
            printf '%s\n' "${CONNECTIONS_ROW}" 2>/dev/null
        fi
        exit 0
        ;;
    connect | exec)
        # The tests assert the exact logged argv of these calls. Selectable
        # failures model the two degrade paths the flow must survive:
        # WORKSHOP_CONNECT_FAIL refuses exactly the openrouter-key connect
        # (a stale-definition instance - the platform has no such plug),
        # WORKSHOP_EXEC_FAIL fails the converger exec (locked keyring /
        # corrupt auth.json inside the instance).
        if [ "$1" = "connect" ] && [ -n "${WORKSHOP_CONNECT_FAIL:-}" ] \
            && [[ "$*" == *openrouter-key* ]]; then
            echo "error: cannot resolve connection: SDK has no plug named openrouter-key" >&2
            exit 1
        fi
        if [ "$1" = "exec" ] && [ -n "${WORKSHOP_EXEC_FAIL:-}" ]; then
            echo "workshopctl get-secret: the host keyring is locked" >&2
            exit 1
        fi
        exit 0
        ;;
    *)
        echo "workshop stub: unsupported invocation: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${root}/bin/workshop"
    cat > "${root}/bin/uv" <<EOF
#!/usr/bin/env bash
# uv shim: run the real module with the system python, as uv run would
# (the setup suite's shim, extended to skip the --project dir pair).
if [ "\$1" = "run" ]; then
    shift
    while [ "\${1:-}" = "--frozen" ]; do shift; done
    if [ "\${1:-}" = "--project" ]; then shift 2; fi
    [ "\${1:-}" = "python" ] && shift
    exec env PYTHONPATH="${PROJECT_DIR}/scripts" python3 "\$@"
fi
echo "uv shim: unsupported invocation: \$*" >&2
exit 1
EOF
    chmod +x "${root}/bin/uv"
}

# Run the fixture's secret-setup.sh with the stubs on PATH. USER is
# neutralized because this suite may run inside the workshop container,
# where USER=workshop would trip the in-container refusal before the flow
# under test; the refusal itself is probed separately. Stdin comes from a
# file so the hidden prompts are fed deterministically.
run_secret() {
    local root=$1 stdin_file=$2
    shift 2
    env -u I_KNOW_WHAT_IM_DOING \
        USER=host \
        PATH="${root}/bin:${PATH}" \
        WORKSHOP_LOG="${root}/workshop.log" \
        SECRET_TOOL_KEYRING="${root}/keyring" \
        bash "${root}/scripts/secret-setup.sh" "$@" < "${stdin_file}"
}

test_or_prompt_stores_and_rerun_skips() (
    local root output
    root=$(new_root); make_fixture "${root}"
    printf '%s\n' "${OR_KEY}" > "${root}/stdin.txt"
    output=$(run_secret "${root}" "${root}/stdin.txt") \
        || fail "no-name run with an OpenRouter key on stdin failed: ${output}"
    grep -q "GitHub token already stored in the host keyring" <<<"${output}" \
        || fail "pre-seeded GitHub entry was not reported already-stored: ${output}"
    grep -q "OpenRouter key stored in the host keyring" <<<"${output}" \
        || fail "OpenRouter key was not stored: ${output}"
    grep -qx "${OR_KEYLINE}" "${root}/keyring" \
        || fail "fixture keyring did not gain the openrouter entry: $(cat "${root}/keyring")"
    [[ $(SECRET_TOOL_KEYRING="${root}/keyring" "${root}/bin/secret-tool" \
        lookup service "${GH_SERVICE}") == "${GH_SEED}" ]] \
        || fail "the GitHub entry did not remain retrievable: $(cat "${root}/keyring")"
    if grep -q "${OR_KEY}" <<<"${output}"; then
        fail "the OpenRouter key leaked into the script output"
    fi
    # Re-run with a different key available on stdin: already-stored must
    # skip the prompt, so the keyring stays byte-identical.
    cp "${root}/keyring" "${root}/keyring.before"
    printf '%s\n' "or-stub-key-unread-999" > "${root}/stdin.txt"
    output=$(run_secret "${root}" "${root}/stdin.txt") \
        || fail "re-run of the stored-key path failed: ${output}"
    grep -q "OpenRouter key already stored in the host keyring" <<<"${output}" \
        || fail "re-run did not report the key as already stored: ${output}"
    cmp -s "${root}/keyring.before" "${root}/keyring" \
        || fail "re-run mutated the keyring despite skip-if-stored: $(cat "${root}/keyring")"
)

test_empty_key_skips_and_continues() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    printf '\n' > "${root}/stdin.txt"
    set +e
    output=$(run_secret "${root}" "${root}/stdin.txt" 2> "${root}/stderr.txt")
    status=$?
    set -e
    [[ ${status} -eq 0 ]] \
        || fail "empty-key input must continue to exit 0, got ${status}: ${output}"
    grep -q "WARNING: no key entered; skipping the OpenRouter key" "${root}/stderr.txt" \
        || fail "empty-key input did not warn on stderr: $(cat "${root}/stderr.txt")"
    if grep -q "^${OR_SERVICE}=" "${root}/keyring"; then
        fail "empty-key input still stored an entry: $(cat "${root}/keyring")"
    fi
    # The GitHub flow completes unaffected - the optional-key path.
    grep -q "GitHub token already stored in the host keyring" <<<"${output}" \
        || fail "GitHub block did not complete after the empty-key skip: ${output}"
    grep -q "gh already authenticated on the host" <<<"${output}" \
        || fail "gh login block did not complete after the empty-key skip: ${output}"
    grep -q "No instance name given; skipping the secret-plug wiring." <<<"${output}" \
        || fail "flow did not reach the no-name exit after the empty-key skip: ${output}"
)

test_not_launched_skips_wiring_and_converger() (
    local root output
    root=$(new_root); make_fixture "${root}"
    printf '%s\n' "${OR_KEY}" > "${root}/stdin.txt"
    output=$(WORKSHOP_INFO_FAIL=1 run_secret "${root}" "${root}/stdin.txt" fixture) \
        || fail "with-name run against a not-launched instance failed: ${output}"
    grep -q "Workshop 'fixture' is not launched yet" <<<"${output}" \
        || fail "missing the not-launched note: ${output}"
    grep -qx "${OR_KEYLINE}" "${root}/keyring" \
        || fail "keyring work must still be done when the instance is not launched"
    grep -q "workshop info fixture" "${root}/workshop.log" \
        || fail "the info probe was not logged: $(cat "${root}/workshop.log")"
    if grep -qE 'workshop (connect|exec|connections)' "${root}/workshop.log"; then
        fail "wiring/converger ran despite the not-launched instance: $(cat "${root}/workshop.log")"
    fi
)

test_ready_wires_stripped_names_and_converges() (
    local root output log
    root=$(new_root); make_fixture "${root}"
    printf '%s\n' "${OR_KEY}" > "${root}/stdin.txt"
    output=$(WORKSHOP_STATUS=Ready run_secret "${root}" "${root}/stdin.txt" fixture) \
        || fail "with-name run against a Ready instance failed: ${output}"
    log="${root}/workshop.log"
    grep -qF "workshop connect fixture/gh-cli:github-token fixture/system:github-token" "${log}" \
        || fail "missing the github connect line: $(cat "${log}")"
    grep -qF "workshop connect fixture/fixture-tools:openrouter-key fixture/system:openrouter-key" "${log}" \
        || fail "missing/wrong openrouter connect line: $(cat "${log}")"
    grep -qF "workshop exec fixture -- bash -c set -euo pipefail; . /project/scripts/hooks/lib-common.sh && write_opencode_auth fixture-tools.openrouter-key" "${log}" \
        || fail "missing/wrong exec converger line: $(cat "${log}")"
    [[ $(grep -c '^workshop connect ' "${log}") -eq 2 ]] \
        || fail "expected exactly two connect lines: $(cat "${log}")"
    if grep -q 'project-' "${log}"; then
        fail "a project- prefixed (non-runtime) SDK name leaked into a workshop call: $(cat "${log}")"
    fi
    grep -q "Converged the opencode auth inside 'fixture'" <<<"${output}" \
        || fail "converger success note missing: ${output}"
)

test_existing_row_skips_reconnect_converger_runs() (
    local root output log
    root=$(new_root); make_fixture "${root}"
    printf '%s\n' "${OR_KEY}" > "${root}/stdin.txt"
    # A REAL connections row: four TAB-separated columns ending in the
    # NOTES value manual - the reason the idempotence grep is unanchored.
    output=$(WORKSHOP_STATUS=Ready \
        CONNECTIONS_ROW=$'secret\tfixture/fixture-tools:openrouter-key\tfixture/system:openrouter-key\tmanual' \
        run_secret "${root}" "${root}/stdin.txt" fixture) \
        || fail "with-name run with an existing connection row failed: ${output}"
    log="${root}/workshop.log"
    grep -q "fixture/fixture-tools:openrouter-key already connected to fixture/system:openrouter-key" <<<"${output}" \
        || fail "the existing openrouter row was not reported already connected: ${output}"
    if grep -qF "workshop connect fixture/fixture-tools:openrouter-key" "${log}"; then
        fail "a second connect was attempted despite the existing row: $(cat "${log}")"
    fi
    grep -qF "workshop connect fixture/gh-cli:github-token fixture/system:github-token" "${log}" \
        || fail "the github connect must still run (the row carries only the openrouter plug): $(cat "${log}")"
    grep -qF "workshop exec fixture -- bash -c set -euo pipefail; . /project/scripts/hooks/lib-common.sh && write_opencode_auth fixture-tools.openrouter-key" "${log}" \
        || fail "converger did not run after the already-connected skip: $(cat "${log}")"
    grep -q "Converged the opencode auth inside 'fixture'" <<<"${output}" \
        || fail "converger success note missing: ${output}"
)

test_stopped_connects_but_skips_converger() (
    local root output log
    root=$(new_root); make_fixture "${root}"
    printf '%s\n' "${OR_KEY}" > "${root}/stdin.txt"
    output=$(WORKSHOP_STATUS=Stopped run_secret "${root}" "${root}/stdin.txt" fixture) \
        || fail "with-name run against a Stopped instance failed: ${output}"
    log="${root}/workshop.log"
    grep -qF "workshop connect fixture/fixture-tools:openrouter-key fixture/system:openrouter-key" "${log}" \
        || fail "the openrouter connect must still be attempted on a Stopped instance: $(cat "${log}")"
    if grep -q 'workshop exec' "${log}"; then
        fail "the converger ran on a not-Ready instance: $(cat "${log}")"
    fi
    grep -q "once the instance is Ready" <<<"${output}" \
        || fail "missing the once-it-is-Ready note: ${output}"
    if grep -q "Converged" <<<"${output}"; then
        fail "a converger success note was printed for a Stopped instance: ${output}"
    fi
)

test_converger_failure_degrades() (
    local root output status log
    root=$(new_root); make_fixture "${root}"
    printf '%s\n' "${OR_KEY}" > "${root}/stdin.txt"
    set +e
    output=$(WORKSHOP_STATUS=Ready WORKSHOP_EXEC_FAIL=1 \
        run_secret "${root}" "${root}/stdin.txt" fixture 2> "${root}/stderr.txt")
    status=$?
    set -e
    log="${root}/workshop.log"
    [[ ${status} -eq 0 ]] \
        || fail "a failed converger must not abort the flow, got exit ${status}: ${output}"
    grep -qF "workshop connect fixture/fixture-tools:openrouter-key fixture/system:openrouter-key" "${log}" \
        || fail "the openrouter connect must still run before the converger: $(cat "${log}")"
    grep -q "workshop exec fixture" "${log}" \
        || fail "the converger exec was not attempted: $(cat "${log}")"
    grep -q "WARNING: the opencode auth converger failed inside 'fixture'" "${root}/stderr.txt" \
        || fail "the converger failure was not reported as a warning: $(cat "${root}/stderr.txt")"
    grep -q "authenticate-opencode" "${root}/stderr.txt" \
        || fail "the troubleshooting pointer was missing: $(cat "${root}/stderr.txt")"
    if grep -q "Converged the opencode auth" <<<"${output}"; then
        fail "a converger success note was printed despite the failure: ${output}"
    fi
)

test_openrouter_connect_refusal_degrades() (
    local root output status log
    root=$(new_root); make_fixture "${root}"
    printf '%s\n' "${OR_KEY}" > "${root}/stdin.txt"
    set +e
    output=$(WORKSHOP_STATUS=Ready WORKSHOP_CONNECT_FAIL=1 \
        run_secret "${root}" "${root}/stdin.txt" fixture 2> "${root}/stderr.txt")
    status=$?
    set -e
    log="${root}/workshop.log"
    [[ ${status} -eq 0 ]] \
        || fail "a refused openrouter connect must not abort the flow, got exit ${status}: ${output}"
    grep -qF "workshop connect fixture/gh-cli:github-token fixture/system:github-token" "${log}" \
        || fail "the mandatory github connect was skipped by the degradation: $(cat "${log}")"
    grep -qF "workshop connect fixture/fixture-tools:openrouter-key fixture/system:openrouter-key" "${log}" \
        || fail "the refused openrouter connect was not attempted: $(cat "${log}")"
    grep -q "WARNING: could not connect fixture/fixture-tools:openrouter-key to fixture/system:openrouter-key" "${root}/stderr.txt" \
        || fail "the connect refusal was not reported as a warning: $(cat "${root}/stderr.txt")"
    grep -q "older definition without the" "${root}/stderr.txt" \
        || fail "the stale-instance cause was not explained: $(cat "${root}/stderr.txt")"
    grep -q "workshop refresh fixture" "${root}/stderr.txt" \
        || fail "the refresh recovery was not offered: $(cat "${root}/stderr.txt")"
    if grep -q "workshop exec" "${log}"; then
        fail "the converger ran despite the refused connect: $(cat "${log}")"
    fi
)

test_in_container_refusal() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    set +e
    output=$(env -u I_KNOW_WHAT_IM_DOING \
        USER=workshop \
        PATH="${root}/bin:${PATH}" \
        bash "${root}/scripts/secret-setup.sh" < /dev/null 2>&1)
    status=$?
    set -e
    [[ ${status} -eq 1 ]] \
        || fail "in-container refusal exited ${status}, want 1: ${output}"
    grep -q "assert-host: this command must be run from the host, not inside the Workshop" <<<"${output}" \
        || fail "refusal message missing: ${output}"
    if grep -q "Enter your" <<<"${output}"; then
        fail "the refusal must precede the prompts: ${output}"
    fi
    if grep -q "^${OR_SERVICE}=" "${root}/keyring"; then
        fail "the refused run still stored a secret: $(cat "${root}/keyring")"
    fi
)

test_or_prompt_stores_and_rerun_skips
test_empty_key_skips_and_continues
test_not_launched_skips_wiring_and_converger
test_ready_wires_stripped_names_and_converges
test_existing_row_skips_reconnect_converger_runs
test_stopped_connects_but_skips_converger
test_converger_failure_degrades
test_openrouter_connect_refusal_degrades
test_in_container_refusal
echo "secret-setup tests passed."
