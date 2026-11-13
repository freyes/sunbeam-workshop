#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for the setup-project hook conventions (todo 22): every profile's
# hook sources scripts/hooks/lib-common.sh, routes provisioning calls
# through run_step (loud but non-fatal; check-health is the gate), and never
# aborts fatally on a missing merged vars doc - plus fixture coverage of the
# shared find_vars_doc helper (bare-name hit, single-profile fallback,
# ambiguous/no match returning 1 without aborting). Fixture state dirs live
# in mktemp roots via SUNBEAM_WORKSHOP_STATE_DIR; the real tree's .state is
# never touched.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
LIB="${PROJECT_DIR}/scripts/hooks/lib-common.sh"
HOOKS_DIR="${PROJECT_DIR}/.workshop"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for find_vars_doc fixtures"

# All fixture roots live under one suite tmp dir so the EXIT trap cleans up
# even when a test subshell fails mid-way.
SUITE_TMP=$(mktemp -d /tmp/sunbeam-hooks-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

PROFILES=(sunbeam charmed packaging)

# A bare provisioning call is one of the shared step functions at line start
# (optional leading whitespace) followed by whitespace OR end-of-line. The
# end-of-line alternative matters: zero-argument bare calls - the original
# charmed/packaging offense shape - carry no trailing whitespace.
BARE_CALL_RE='^[[:space:]]*(install_uv_pythons|build_tox_venv|seed_atlassian_mcp|install_agentic_skills|pin_forge_host_keys|apply_git_identity|write_ppa_profile)([[:space:]]|$)'

# Fixture filenames used by the fallback tests must never collide with the
# test host's own hostname, or the primary lookup would hit them.
HOSTNAME_NOW=$(hostname)
for reserved in instance-one instance-two instance-other; do
    [ "$HOSTNAME_NOW" != "$reserved" ] \
        || fail "fixture name '$reserved' collides with the test hostname"
done

hook_path() {
    echo "${HOOKS_DIR}/$1-tools/hooks/setup-project"
}

# assert_run_step_count <hook> - the hook routes provisioning through
# run_step (the definition plus the shared steps puts the grep count >= 5).
assert_run_step_count() {
    local hook="$1"
    local count
    count=$(grep -c 'run_step' "$hook")
    [ "$count" -ge 5 ] \
        || fail "$hook: run_step appears $count time(s), want >= 5"
}

# assert_no_bare_provisioning_calls <hook> - no shared provisioning step is
# invoked bare (bypassing run_step). Usable against fixture hooks: `fail`
# exits only the calling (sub)shell, so probe it as `( assert_... )`.
assert_no_bare_provisioning_calls() {
    local hook="$1"
    if grep -qE "$BARE_CALL_RE" "$hook"; then
        grep -nE "$BARE_CALL_RE" "$hook" >&2
        fail "$hook: bare provisioning call bypasses run_step"
    fi
}

test_hooks_source_lib_common() {
    local profile hook
    for profile in "${PROFILES[@]}"; do
        hook=$(hook_path "$profile")
        grep -q '^# shellcheck source=scripts/hooks/lib-common\.sh$' "$hook" \
            || fail "$hook lacks the shellcheck source directive for lib-common.sh"
        grep -q '^\. /project/scripts/hooks/lib-common\.sh$' "$hook" \
            || fail "$hook does not source /project/scripts/hooks/lib-common.sh"
    done
}

test_provisioning_calls_go_through_run_step() {
    local profile hook
    for profile in "${PROFILES[@]}"; do
        hook=$(hook_path "$profile")
        assert_run_step_count "$hook"
        assert_no_bare_provisioning_calls "$hook"
    done
}

test_bare_call_assertion_catches_zero_arg_mutant() (
    local fixture_hook status
    fixture_hook="${SUITE_TMP}/mutant-hook"
    # The pre-todo-22 offense shape: bare zero-argument provisioning calls,
    # each at end-of-line with no trailing whitespace.
    cat > "$fixture_hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
seed_atlassian_mcp
install_agentic_skills
pin_forge_host_keys
EOF
    set +e
    ( assert_no_bare_provisioning_calls "$fixture_hook" ) 2>/dev/null
    status=$?
    set -e
    [ "$status" -ne 0 ] \
        || fail "bare zero-argument provisioning calls escaped detection in a mutant hook"
)

test_charmed_vars_doc_lookup_never_fatal() {
    local hook region
    hook=$(hook_path charmed)
    if grep -qE '\$\(hostname\)\.vars\.json' "$hook"; then
        fail "$hook still does a raw \$(hostname).vars.json lookup (find_vars_doc owns that)"
    fi
    region=$(sed -n '/vars_doc/,/fi/p' "$hook")
    if grep -qE 'exit 1' <<<"$region"; then
        fail "$hook still exits 1 on a missing vars doc"
    fi
    if grep -q 'exit 1' "$hook"; then
        fail "$hook contains exit 1; a missing vars doc must warn + skip, never abort"
    fi
}

make_state_dir() {
    mktemp -d "${SUITE_TMP}/state.XXXXXX"
}

write_vars_doc() {
    printf '{"profile": "%s"}\n' "$2" > "$1"
}

run_find_vars_doc() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    SUNBEAM_WORKSHOP_STATE_DIR="$1" find_vars_doc "$2"
)

test_find_vars_doc_bare_name_hit() (
    local state_dir host_doc got
    state_dir=$(make_state_dir)
    host_doc="${state_dir}/${HOSTNAME_NOW}.vars.json"
    write_vars_doc "$host_doc" fixture
    # A same-profile doc under another name must NOT win over the primary.
    write_vars_doc "${state_dir}/instance-one.vars.json" fixture
    got=$(run_find_vars_doc "$state_dir" fixture) \
        || fail "find_vars_doc returned non-zero with a bare-name doc present"
    [ "$got" = "$host_doc" ] \
        || fail "bare-name hit resolved to '$got', want '$host_doc'"
)

test_find_vars_doc_single_profile_fallback() (
    local state_dir doc got
    state_dir=$(make_state_dir)
    doc="${state_dir}/instance-one.vars.json"
    write_vars_doc "$doc" fixture
    # A doc of another profile must be ignored by the fallback scan.
    write_vars_doc "${state_dir}/instance-other.vars.json" other
    got=$(run_find_vars_doc "$state_dir" fixture) \
        || fail "find_vars_doc returned non-zero with exactly one fixture-profile doc"
    [ "$got" = "$doc" ] \
        || fail "fallback resolved to '$got', want '$doc'"
)

test_find_vars_doc_multi_match_returns_1() (
    local state_dir got status
    state_dir=$(make_state_dir)
    write_vars_doc "${state_dir}/instance-one.vars.json" fixture
    write_vars_doc "${state_dir}/instance-two.vars.json" fixture
    set +e
    got=$(run_find_vars_doc "$state_dir" fixture); status=$?
    set -e
    [ "$status" -eq 1 ] \
        || fail "multi-match: status $status, want 1 (no abort); output: '$got'"
    [ -z "$got" ] || fail "multi-match printed '$got' to stdout, want empty"
)

test_find_vars_doc_no_match_returns_1() (
    local state_dir got status
    state_dir=$(make_state_dir)
    write_vars_doc "${state_dir}/instance-other.vars.json" other
    set +e
    got=$(run_find_vars_doc "$state_dir" fixture); status=$?
    set -e
    [ "$status" -eq 1 ] \
        || fail "no-match: status $status, want 1 (no abort); output: '$got'"
    [ -z "$got" ] || fail "no-match printed '$got' to stdout, want empty"
)

test_hooks_source_lib_common
test_provisioning_calls_go_through_run_step
test_bare_call_assertion_catches_zero_arg_mutant
test_charmed_vars_doc_lookup_never_fatal
test_find_vars_doc_bare_name_hit
test_find_vars_doc_single_profile_fallback
test_find_vars_doc_multi_match_returns_1
test_find_vars_doc_no_match_returns_1
echo "hooks tests passed."
