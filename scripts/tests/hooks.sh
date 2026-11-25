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
# mktemp dirs via OPENSTACK_WORKSHOP_STATE_DIR, OPENSTACK_WORKSHOP_FRAGMENT_ROOT
# and XDG_STATE_HOME; the real tree's state is never touched.
# The write_opencode_auth / check_opencode_auth contract is covered too:
# PATH-stubbed workshopctl/systemctl fixtures (mktemp HOME, deterministic -
# no sleeps, no timing, no network) drive the writer through happy write
# (managed shape, mode 600, exactly one agent-unit restart), compare-skip
# (no systemctl entries, byte-identical file), changed-key restart,
# inactive-unit no-restart, get-secret rc 3 warn-and-skip, a bash -x probe
# asserting the key never leaks into a trace, and the foreign-content
# replacement warning; the corrupt-only gate is driven with absent, valid,
# malformed and empty-key files.
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
BARE_CALL_RE='^[[:space:]]*(install_uv_pythons|build_tox_venv|seed_atlassian_mcp|install_agentic_skills|pin_forge_host_keys|apply_git_identity|write_ppa_profile|write_opencode_auth)([[:space:]]|$)'

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

# Every setup-project hook routes write_opencode_auth through run_step with
# its profile-specific plug spec (the RUNTIME SDK name - workshopctl
# get-secret rejects project--prefixed specs).
test_setup_project_wires_write_opencode_auth() {
    local profile hook expected
    for profile in "${PROFILES[@]}"; do
        hook=$(hook_path "$profile")
        expected="run_step \"write_opencode_auth\" write_opencode_auth ${profile}-tools.openrouter-key"
        grep -qF "$expected" "$hook" \
            || fail "$hook lacks the exact '$expected' run_step wiring"
    done
}

# Every check-health hook carries the corrupt-opencode-auth gate, and the
# gate precedes the final set-health okay (a gate after it could never
# fire).
test_check_health_opencode_auth_gate_precedes_okay() {
    local profile hook gate_line okay_line
    for profile in "${PROFILES[@]}"; do
        hook=$(check_health_path "$profile")
        grep -q 'corrupt-opencode-auth' "$hook" \
            || fail "$hook lacks the corrupt-opencode-auth gate"
        gate_line=$(grep -n 'corrupt-opencode-auth' "$hook" | head -n 1 | cut -d: -f1 || true)
        okay_line=$(grep -n 'workshopctl set-health okay' "$hook" | tail -n 1 | cut -d: -f1 || true)
        [ -n "$gate_line" ] || fail "$hook: corrupt-opencode-auth gate line not found"
        [ -n "$okay_line" ] || fail "$hook lacks the final workshopctl set-health okay"
        [ "$gate_line" -lt "$okay_line" ] \
            || fail "$hook: auth gate (line $gate_line) must precede set-health okay (line $okay_line)"
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
    OPENSTACK_WORKSHOP_STATE_DIR="$1" find_vars_doc "$2"
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
    OPENSTACK_WORKSHOP_FRAGMENT_ROOT="$root" run_user_fragments setup-project fixture 2>/dev/null
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
    OPENSTACK_WORKSHOP_FRAGMENT_ROOT="$root" run_user_fragments setup-project fixture 2>"$err"
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
    OPENSTACK_WORKSHOP_FRAGMENT_ROOT="$root" \
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
    [ -e "$state/openstack-workshop/run-once/my-marker" ] \
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
    OPENSTACK_WORKSHOP_FRAGMENT_ROOT="$root" run_user_fragments setup-project fixture 2>/dev/null \
        || fail "non-.sh files must be ignored, got a failure"
)

# A missing fragment root and empty .d dirs are a silent no-op: status 0,
# nothing on stdout or stderr.
test_missing_fragment_root_is_noop() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    out=$(OPENSTACK_WORKSHOP_FRAGMENT_ROOT="${SUITE_TMP}/does-not-exist" run_user_fragments setup-project fixture 2>&1) \
        || fail "missing fragment root: non-zero status, want a silent no-op"
    [ -z "$out" ] \
        || fail "missing fragment root: expected silence, got '$out'"
    root=$(make_frag_root)
    mkdir -p "$root/all/setup-project.d"
    out=$(OPENSTACK_WORKSHOP_FRAGMENT_ROOT="$root" run_user_fragments setup-project fixture 2>&1) \
        || fail "empty fragment dirs: non-zero status, want a silent no-op"
    [ -z "$out" ] \
        || fail "empty fragment dirs: expected silence, got '$out'"
)

# --- write_opencode_auth / check_opencode_auth fixtures -------------------
# Deterministic PATH stubs (no sleeps, no timing, no network - they only
# read env vars and append to log files): workshopctl answers `get-secret`
# with $STUB_KEY (default fake key) or exits $STUB_GET_SECRET_RC; systemctl
# logs every invocation to $SYSTEMCTL_LOG and answers `is-active` with
# $STUB_IS_ACTIVE_RC (default 0 = active). Every writer run uses a mktemp
# HOME, so the real tree's state is never touched.
STUB_DIR=$(mktemp -d "${SUITE_TMP}/stubs.XXXXXX")
cat > "${STUB_DIR}/workshopctl" <<'EOF'
#!/usr/bin/env bash
# workshopctl stub for the write_opencode_auth fixtures.
[ "${1:-}" = get-secret ] || { echo "workshopctl stub: unsupported call: $*" >&2; exit 64; }
if [ -n "${STUB_GET_SECRET_RC:-}" ]; then
    exit "${STUB_GET_SECRET_RC}"
fi
printf '%s' "${STUB_KEY:-test-stub-or-key-12345}"
EOF
cat > "${STUB_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
# systemctl stub for the write_opencode_auth fixtures.
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?SYSTEMCTL_LOG must name the stub log}"
case " $* " in
    *" is-active "*) exit "${STUB_IS_ACTIVE_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "${STUB_DIR}/workshopctl" "${STUB_DIR}/systemctl"

AUTH_REL=".local/share/opencode/auth.json"

make_writer_home() {
    mktemp -d "${SUITE_TMP}/writer-home.XXXXXX"
}

# (a) happy write: the file exists with the exact managed shape, mode 600,
# and exactly one restart of the agent unit.
test_write_opencode_auth_happy_write() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local home auth_file log err status restarts
    home=$(make_writer_home)
    auth_file="$home/${AUTH_REL}"
    log="$home/systemctl.log"
    err="$home/stderr.log"
    : > "$log"
    set +e
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$log" \
        write_opencode_auth sunbeam-tools.openrouter-key 2>"$err"
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "happy write: status $status, want 0"
    [ -f "$auth_file" ] || fail "happy write: $auth_file was not written"
    jq -e '.openrouter.type == "api" and .openrouter.key == "test-stub-or-key-12345"' "$auth_file" >/dev/null \
        || fail "happy write: $auth_file is not the managed openrouter shape"
    [ "$(stat -c '%a' "$auth_file")" = "600" ] \
        || fail "happy write: mode is $(stat -c '%a' "$auth_file"), want 600"
    restarts=$(grep -c 'restart openchamber-opencode.service' "$log" || true)
    [ "$restarts" -eq 1 ] \
        || fail "happy write: $restarts restart(s) logged, want exactly 1"
)

# (b) compare-skip: a second run with the same key adds NO systemctl
# entries and leaves the file byte-identical (convergence without side
# effects).
test_write_opencode_auth_compare_skip() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local home auth_file log err out lines_before lines_after
    home=$(make_writer_home)
    auth_file="$home/${AUTH_REL}"
    log="$home/systemctl.log"
    err="$home/stderr.log"
    out="$home/stdout.log"
    : > "$log"
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$log" \
        write_opencode_auth sunbeam-tools.openrouter-key >"$out" 2>"$err" \
        || fail "compare-skip: first run failed"
    cp "$auth_file" "$home/first-run.json"
    lines_before=$(wc -l < "$log")
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$log" \
        write_opencode_auth sunbeam-tools.openrouter-key >"$out" 2>"$err" \
        || fail "compare-skip: second run failed"
    lines_after=$(wc -l < "$log")
    [ "$lines_after" -eq "$lines_before" ] \
        || fail "compare-skip: systemctl log grew from $lines_before to $lines_after entries, want no new entries"
    cmp -s "$home/first-run.json" "$auth_file" \
        || fail "compare-skip: auth.json is not byte-identical after the second run"
    grep -q 'already up to date' "$out" \
        || fail "compare-skip: second run did not take the compare-skip branch"
)

# (c) changed key: a rotated stub key rewrites the file and restarts the
# agent unit exactly once more.
test_write_opencode_auth_changed_key_restarts() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local home auth_file log err restarts_before restarts_after
    home=$(make_writer_home)
    auth_file="$home/${AUTH_REL}"
    log="$home/systemctl.log"
    err="$home/stderr.log"
    : > "$log"
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$log" \
        write_opencode_auth sunbeam-tools.openrouter-key 2>"$err" \
        || fail "changed key: first run failed"
    restarts_before=$(grep -c 'restart openchamber-opencode.service' "$log" || true)
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$log" \
        STUB_KEY="test-stub-or-key-rotated-678" \
        write_opencode_auth sunbeam-tools.openrouter-key 2>"$err" \
        || fail "changed key: second run failed"
    restarts_after=$(grep -c 'restart openchamber-opencode.service' "$log" || true)
    [ "$((restarts_after - restarts_before))" -eq 1 ] \
        || fail "changed key: $((restarts_after - restarts_before)) new restart(s), want exactly 1"
    jq -e '.openrouter.key == "test-stub-or-key-rotated-678"' "$auth_file" >/dev/null \
        || fail "changed key: auth.json does not carry the rotated key"
)

# (d) inactive unit: is-active exits 3 -> the file is still written and NO
# restart is attempted.
test_write_opencode_auth_inactive_unit_no_restart() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local home auth_file log err out status restarts
    home=$(make_writer_home)
    auth_file="$home/${AUTH_REL}"
    log="$home/systemctl.log"
    err="$home/stderr.log"
    out="$home/stdout.log"
    : > "$log"
    set +e
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$log" \
        STUB_IS_ACTIVE_RC=3 \
        write_opencode_auth sunbeam-tools.openrouter-key >"$out" 2>"$err"
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "inactive unit: status $status, want 0"
    [ -f "$auth_file" ] || fail "inactive unit: $auth_file was not written"
    jq -e '.openrouter.key == "test-stub-or-key-12345"' "$auth_file" >/dev/null \
        || fail "inactive unit: auth.json does not carry the stub key"
    restarts=$(grep -c 'restart openchamber-opencode.service' "$log" || true)
    [ "$restarts" -eq 0 ] \
        || fail "inactive unit: $restarts restart(s) logged, want 0"
    grep -q 'no restart' "$out" \
        || fail "inactive unit: the no-restart branch did not run"
)

# (e) get-secret rc 3 (plug not connected): loud warning, no file, and the
# function still returns 0 - an absent secret must never fail a hook.
test_write_opencode_auth_rc3_warns_and_skips() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local home auth_file err status
    home=$(make_writer_home)
    auth_file="$home/${AUTH_REL}"
    err="$home/stderr.log"
    set +e
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$home/systemctl.log" \
        STUB_GET_SECRET_RC=3 \
        write_opencode_auth sunbeam-tools.openrouter-key 2>"$err"
    status=$?
    set -e
    [ "$status" -eq 0 ] \
        || fail "rc 3: status $status, want 0 (an absent secret must not fail the hook)"
    [ ! -e "$auth_file" ] || fail "rc 3: $auth_file was created, want no file"
    grep -q 'not connected yet' "$err" \
        || fail "rc 3: stderr lacks the not-connected-yet warning"
)

# (f) xtrace-leak probe: run the happy path under `bash -x` with stderr
# captured and assert the fake key never appears in the trace. The probe
# MUST take the happy path (stub returns the key, file written) so the
# trace actually flows the key through the suppressed regions - a
# failing-stub run would never expand $key and pass vacuously. PS4 is
# pinned so the trace-presence grep is deterministic.
test_write_opencode_auth_xtrace_never_leaks_key() (
    set -euo pipefail
    local home auth_file err status
    home=$(make_writer_home)
    auth_file="$home/${AUTH_REL}"
    err="$home/xtrace.err"
    : > "$err"
    set +e
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$home/systemctl.log" \
        LIB="$LIB" PS4='+ ' \
        bash -x -c 'set -euo pipefail; . "$LIB"; write_opencode_auth sunbeam-tools.openrouter-key' 2>"$err"
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "xtrace probe: status $status, want 0"
    [ -f "$auth_file" ] \
        || fail "xtrace probe: happy path not taken - $auth_file missing"
    jq -e '.openrouter.key == "test-stub-or-key-12345"' "$auth_file" >/dev/null \
        || fail "xtrace probe: happy path not taken - auth.json lacks the stub key"
    grep -q 'write_opencode_auth' "$err" \
        || fail "xtrace probe: no trace captured - the leak assertion would pass vacuously"
    if grep -q 'test-stub-or-key-12345' "$err"; then
        fail "xtrace probe: key material leaked into the bash -x trace"
    fi
)

# (g) foreign content: a pre-existing valid auth.json with an extra
# top-level provider key triggers a loud WARNING and is still replaced by
# the managed openrouter-only shape.
test_write_opencode_auth_foreign_content_warning() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local home auth_file err status
    home=$(make_writer_home)
    auth_file="$home/${AUTH_REL}"
    err="$home/stderr.log"
    mkdir -p "$home/.local/share/opencode"
    printf '%s\n' '{"openrouter": {"type": "api", "key": "old-manual-key"}, "github-copilot": {"token": "manual"}}' > "$auth_file"
    set +e
    PATH="${STUB_DIR}:${PATH}" HOME="$home" SYSTEMCTL_LOG="$home/systemctl.log" \
        write_opencode_auth sunbeam-tools.openrouter-key 2>"$err"
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "foreign content: status $status, want 0"
    grep -q 'WARNING' "$err" \
        || fail "foreign content: stderr lacks the loud WARNING"
    jq -e 'keys == ["openrouter"] and .openrouter.type == "api" and .openrouter.key == "test-stub-or-key-12345"' "$auth_file" >/dev/null \
        || fail "foreign content: auth.json was not converged to the managed openrouter-only shape"
)

# check_opencode_auth gate fixtures: corrupt-only semantics - absent and
# valid files pass, malformed and empty-key files fail with the file named.
test_check_opencode_auth_absent_passes() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local dir status
    dir=$(make_state_dir)
    set +e
    check_opencode_auth "$dir/no-such-auth.json"
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "gate: absent file must pass, got $status"
)

test_check_opencode_auth_valid_passes() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local dir status
    dir=$(make_state_dir)
    printf '{"openrouter": {"type": "api", "key": "some-key"}}\n' > "$dir/auth.json"
    set +e
    check_opencode_auth "$dir/auth.json"
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "gate: valid file must pass, got $status"
)

test_check_opencode_auth_malformed_fails() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local dir err status
    dir=$(make_state_dir)
    err="$dir/stderr.log"
    printf 'not json at all\n' > "$dir/auth.json"
    set +e
    check_opencode_auth "$dir/auth.json" 2>"$err"
    status=$?
    set -e
    [ "$status" -eq 1 ] || fail "gate: malformed file: status $status, want 1"
    grep -Fq "$dir/auth.json" "$err" \
        || fail "gate: malformed file: failure line does not name the file"
)

test_check_opencode_auth_empty_key_fails() (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$LIB"
    local dir status
    dir=$(make_state_dir)
    printf '{"openrouter": {"type": "api", "key": ""}}\n' > "$dir/auth.json"
    set +e
    check_opencode_auth "$dir/auth.json" 2>/dev/null
    status=$?
    set -e
    [ "$status" -eq 1 ] || fail "gate: empty-key file: status $status, want 1"
)

test_hooks_source_lib_common
test_check_health_sources_lib_common
test_provisioning_calls_go_through_run_step
test_fragments_call_is_last_run_step
test_check_health_fragment_block_precedes_okay
test_setup_project_wires_write_opencode_auth
test_check_health_opencode_auth_gate_precedes_okay
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
test_write_opencode_auth_happy_write
test_write_opencode_auth_compare_skip
test_write_opencode_auth_changed_key_restarts
test_write_opencode_auth_inactive_unit_no_restart
test_write_opencode_auth_rc3_warns_and_skips
test_write_opencode_auth_xtrace_never_leaks_key
test_write_opencode_auth_foreign_content_warning
test_check_opencode_auth_absent_passes
test_check_opencode_auth_valid_passes
test_check_opencode_auth_malformed_fails
test_check_opencode_auth_empty_key_fails
echo "hooks tests passed."
