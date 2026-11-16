#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for the setup-project hook conventions (todo 22): every profile's
# hook sources scripts/hooks/lib-common.sh, routes provisioning calls
# through run_step (loud but non-fatal; check-health is the gate), and never
# aborts fatally on a missing merged vars doc - plus fixture coverage of the
# shared find_vars_doc helper (bare-name hit, single-profile fallback,
# ambiguous/no match returning 1 without aborting). The user lifecycle
# fragment mechanism is gated too: every check-health sources lib-common and
# runs its fragment set fail-hard before the final set-health okay, every
# setup-project ends in the fail-soft fragments run_step, and functional
# fixtures drive run_user_fragments (scope order all->profile->instance,
# lexical order, failure collection, subshell isolation, fail-soft via
# run_step, non-.sh files ignored, missing/empty roots a silent no-op) and
# run_once (first call records, second is skipped). Fixture roots live in
# mktemp dirs via SUNBEAM_WORKSHOP_STATE_DIR, SUNBEAM_WORKSHOP_FRAGMENT_ROOT
# and XDG_STATE_HOME; the real tree's state is never touched.
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

check_health_path() {
    echo "${HOOKS_DIR}/$1-tools/hooks/check-health"
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

test_check_health_sources_lib_common() {
    local profile hook
    for profile in "${PROFILES[@]}"; do
        hook=$(check_health_path "$profile")
        grep -q '^# shellcheck source=scripts/hooks/lib-common\.sh$' "$hook" \
            || fail "$hook lacks the shellcheck source directive for lib-common.sh"
        grep -q '^\. /project/scripts/hooks/lib-common\.sh$' "$hook" \
            || fail "$hook does not source /project/scripts/hooks/lib-common.sh"
    done
}

# The user fragments call must be the LAST run_step invocation in every
# setup-project hook: fragments customize what provisioning produced, so
# nothing may run after them.
test_fragments_call_is_last_run_step() {
    local profile hook last
    for profile in "${PROFILES[@]}"; do
        hook=$(hook_path "$profile")
        last=$(grep 'run_step "' "$hook" | tail -n 1 || true)
        [ "$last" = "run_step \"user fragments\" run_user_fragments setup-project $profile" ] \
            || fail "$hook: last run_step invocation is '$last', want the user fragments call"
    done
}

# check-health runs fragments fail-hard: the run_user_fragments block must
# precede the final workshopctl set-health okay, or a failing fragment
# could not gate Ready.
test_check_health_fragment_block_precedes_okay() {
    local profile hook frag_line okay_line
    for profile in "${PROFILES[@]}"; do
        hook=$(check_health_path "$profile")
        frag_line=$(grep -n "run_user_fragments check-health $profile" "$hook" | tail -n 1 | cut -d: -f1 || true)
        [ -n "$frag_line" ] \
            || fail "$hook lacks the run_user_fragments check-health call"
        okay_line=$(grep -n 'workshopctl set-health okay' "$hook" | tail -n 1 | cut -d: -f1 || true)
        [ -n "$okay_line" ] \
            || fail "$hook lacks the final workshopctl set-health okay"
        [ "$frag_line" -lt "$okay_line" ] \
            || fail "$hook: fragment block (line $frag_line) must precede set-health okay (line $okay_line)"
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

make_frag_root() {
    mktemp -d "${SUITE_TMP}/frag-root.XXXXXX"
}

# write_fragment <path> <body> - create a fixture fragment, parent dirs
# included. The body is a single line of shell sourced by run_user_fragments.
write_fragment() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
}

# Scope order all -> profile -> instance, lexical order within one .d dir.
# The instance scope uses the test host's own hostname, exercising the real
# $(hostname) lookup with no stubbing.
test_fragment_scope_and_lexical_order() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    root=$(make_frag_root)
    log="$root/order.log"
    write_fragment "$root/all/setup-project.d/02-second.sh" "echo 02-second >> \"$log\""
    write_fragment "$root/all/setup-project.d/01-first.sh" "echo 01-first >> \"$log\""
    write_fragment "$root/fixture/setup-project.d/10-prof.sh" "echo 10-prof >> \"$log\""
    write_fragment "$root/$HOSTNAME_NOW/setup-project.d/05-inst.sh" "echo 05-inst >> \"$log\""
    SUNBEAM_WORKSHOP_FRAGMENT_ROOT="$root" run_user_fragments setup-project fixture 2>/dev/null
    got=$(paste -sd, "$log")
    [ "$got" = "01-first,02-second,10-prof,05-inst" ] \
        || fail "fragment order: got '$got', want '01-first,02-second,10-prof,05-inst'"
)

# A failing fragment (exit 3) is recorded by basename in
# USER_FRAGMENT_FAILURES, the run returns 1, the failure is loud on stderr,
# and the subshell isolation keeps the loop alive: the lexically-later
# zz-after fragment still runs.
test_fragment_failure_collected() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    root=$(make_frag_root)
    write_fragment "$root/all/setup-project.d/99-bad.sh" "exit 3"
    write_fragment "$root/all/setup-project.d/zz-after.sh" "echo after > \"$root/after.marker\""
    err="$root/stderr.log"
    set +e
    SUNBEAM_WORKSHOP_FRAGMENT_ROOT="$root" run_user_fragments setup-project fixture 2>"$err"
    status=$?
    set -e
    [ "$status" -eq 1 ] \
        || fail "failing fragment: status $status, want 1"
    [ "${#USER_FRAGMENT_FAILURES[@]}" -eq 1 ] \
        || fail "failing fragment: ${#USER_FRAGMENT_FAILURES[@]} failure(s) recorded, want 1"
    [ "${USER_FRAGMENT_FAILURES[0]}" = "99-bad" ] \
        || fail "failing fragment: recorded '${USER_FRAGMENT_FAILURES[0]}', want '99-bad'"
    [ -f "$root/after.marker" ] \
        || fail "failing fragment killed the run: zz-after never executed (subshell isolation broken)"
    grep -q '99-bad' "$err" \
        || fail "failing fragment: stderr lacks the loud per-fragment lines"
)

# setup-project's fail-soft path: run_step swallows the fragment failure, so
# the hook continues and exits 0.
test_run_step_fail_soft_on_fragment_failure() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    root=$(make_frag_root)
    write_fragment "$root/all/setup-project.d/99-bad.sh" "exit 3"
    SUNBEAM_WORKSHOP_FRAGMENT_ROOT="$root" \
        run_step "user fragments" run_user_fragments setup-project fixture 2>/dev/null \
        || fail "run_step must swallow a fragment failure (fail-soft), got non-zero"
)

# run_once: first call records the marker and returns 0; the second returns
# 1, so a re-run hook skips one-shot work.
test_run_once_records_marker() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    state=$(make_state_dir)
    export XDG_STATE_HOME="$state"
    run_once my-marker \
        || fail "run_once first call must return 0"
    [ -e "$state/sunbeam-workshop/run-once/my-marker" ] \
        || fail "run_once did not record its marker"
    set +e
    run_once my-marker
    status=$?
    set -e
    [ "$status" -eq 1 ] \
        || fail "run_once second call: status $status, want 1"
)

# Only *.sh files are sourced; anything else in a .d dir is ignored even
# when sourcing it would fail.
test_non_sh_files_ignored() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    root=$(make_frag_root)
    write_fragment "$root/all/setup-project.d/01-not-a-fragment.txt" "exit 9"
    write_fragment "$root/all/setup-project.d/README" "exit 9"
    SUNBEAM_WORKSHOP_FRAGMENT_ROOT="$root" run_user_fragments setup-project fixture 2>/dev/null \
        || fail "non-.sh files must be ignored, got a failure"
)

# A missing fragment root and empty .d dirs are a silent no-op: status 0,
# nothing on stdout or stderr.
test_missing_fragment_root_is_noop() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    out=$(SUNBEAM_WORKSHOP_FRAGMENT_ROOT="${SUITE_TMP}/does-not-exist" run_user_fragments setup-project fixture 2>&1) \
        || fail "missing fragment root: non-zero status, want a silent no-op"
    [ -z "$out" ] \
        || fail "missing fragment root: expected silence, got '$out'"
    root=$(make_frag_root)
    mkdir -p "$root/all/setup-project.d"
    out=$(SUNBEAM_WORKSHOP_FRAGMENT_ROOT="$root" run_user_fragments setup-project fixture 2>&1) \
        || fail "empty fragment dirs: non-zero status, want a silent no-op"
    [ -z "$out" ] \
        || fail "empty fragment dirs: expected silence, got '$out'"
)

test_hooks_source_lib_common
test_check_health_sources_lib_common
test_provisioning_calls_go_through_run_step
test_fragments_call_is_last_run_step
test_check_health_fragment_block_precedes_okay
test_bare_call_assertion_catches_zero_arg_mutant
test_charmed_vars_doc_lookup_never_fatal
test_find_vars_doc_bare_name_hit
test_find_vars_doc_single_profile_fallback
test_find_vars_doc_multi_match_returns_1
test_find_vars_doc_no_match_returns_1
test_fragment_scope_and_lexical_order
test_fragment_failure_collected
test_run_step_fail_soft_on_fragment_failure
test_run_once_records_marker
test_non_sh_files_ignored
test_missing_fragment_root_is_noop
echo "hooks tests passed."
