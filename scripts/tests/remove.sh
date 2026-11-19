#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for scripts/remove.sh - the `just remove NAME` behavior.
# The REAL remove.sh runs from a fixture tree: a stub `workshop` binary on
# PATH logs every call and answers per WORKSHOP_REMOVE_MODE, so all three
# contract paths (launched passthrough, not-launched definition cleanup,
# other-failure propagation) are exercised without touching the host or the
# real tree's .workshop/ definitions.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
REMOVE="${PROJECT_DIR}/scripts/remove.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# All fixture roots live under one suite tmp dir so the EXIT trap cleans up
# even when a test subshell fails mid-way.
SUITE_TMP=$(mktemp -d /tmp/sunbeam-remove-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

new_root() {
    mktemp -d "${SUITE_TMP}/root.XXXXXX"
}

# Fixture tree: empty root with a stub `workshop` on bin/. The stub answers
# `workshop remove NAME` per WORKSHOP_REMOVE_MODE:
#   ok            exit 0 (launched instance removed)
#   not-launched  exit 1 with the platform's "workshop not launched" refusal
#   broken        exit 1 with an unrelated failure (e.g. LXD down)
make_fixture() {
    local root=$1
    mkdir -p "${root}/bin" "${root}/.workshop"
    cat > "${root}/bin/workshop" <<'EOF'
#!/usr/bin/env bash
# workshop stub: log every call; remove answers per WORKSHOP_REMOVE_MODE.
echo "workshop $*" >> "$WORKSHOP_LOG"
case "${WORKSHOP_REMOVE_MODE:-ok}" in
    ok)
        echo "removed"
        ;;
    not-launched)
        echo "error: cannot remove \"${2:-}\": workshop not launched" >&2
        exit 1
        ;;
    broken)
        echo "error: LXD is down" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${root}/bin/workshop"
}

run_remove() {
    local root=$1 name=$2
    env PATH="${root}/bin:${PATH}" \
        WORKSHOP_LOG="${root}/workshop.log" \
        SUNBEAM_WORKSHOP_ROOT="${root}" \
        bash "${REMOVE}" "${name}"
}

make_definition() {
    local root=$1 name=$2
    printf 'name: %s\nbase: ubuntu@26.04\n' "${name}" > "${root}/.workshop/${name}.yaml"
}

test_launched_passthrough_keeps_definition() (
    local root output def
    root=$(new_root); make_fixture "${root}"
    make_definition "${root}" fixture
    output=$(run_remove "${root}" fixture) || fail "launched remove failed: ${output}"
    grep -qx 'removed' <<<"${output}" || fail "passthrough output lost: ${output}"
    def="${root}/.workshop/fixture.yaml"
    [ -f "$def" ] || fail "passthrough must not delete the definition: ${def} gone"
    grep -qx 'workshop remove fixture' "${root}/workshop.log" \
        || fail "workshop remove was not called: $(cat "${root}/workshop.log")"
)

test_not_launched_removes_definition() (
    local root output def
    root=$(new_root); make_fixture "${root}"
    make_definition "${root}" fixture-keystone
    output=$(WORKSHOP_REMOVE_MODE=not-launched run_remove "${root}" fixture-keystone) \
        || fail "not-launched remove failed: ${output}"
    def="${root}/.workshop/fixture-keystone.yaml"
    [ ! -f "$def" ] || fail "definition was not removed: ${def} still exists"
    grep -q "Removed rendered definition" <<<"${output}" \
        || fail "no removal report: ${output}"
)

test_other_failure_propagates_rc_and_keeps_definition() (
    local root output status def
    root=$(new_root); make_fixture "${root}"
    make_definition "${root}" fixture
    output=$(WORKSHOP_REMOVE_MODE=broken run_remove "${root}" fixture 2>&1) && status=0 || status=$?
    [ "$status" -eq 1 ] || fail "unrelated failure exit code was ${status}, want 1: ${output}"
    grep -q 'LXD is down' <<<"${output}" || fail "failure output was swallowed: ${output}"
    def="${root}/.workshop/fixture.yaml"
    [ -f "$def" ] || fail "unrelated failure must not delete the definition: ${def} gone"
)

test_not_launched_without_definition_propagates_error() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    output=$(WORKSHOP_REMOVE_MODE=not-launched run_remove "${root}" fixture 2>&1) && status=0 || status=$?
    [ "$status" -eq 1 ] || fail "no-definition exit code was ${status}, want 1: ${output}"
    grep -q 'not launched' <<<"${output}" || fail "refusal output was swallowed: ${output}"
)

test_usage_errors_without_workshop_call() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    output=$(run_remove "${root}" "" 2>&1) && status=0 || status=$?
    [ "$status" -eq 2 ] || fail "empty-name exit code was ${status}, want 2: ${output}"
    [ ! -f "${root}/workshop.log" ] || fail "workshop was called for usage error: $(cat "${root}/workshop.log")"
)

test_launched_passthrough_keeps_definition
test_not_launched_removes_definition
test_other_failure_propagates_rc_and_keeps_definition
test_not_launched_without_definition_propagates_error
test_usage_errors_without_workshop_call
echo "remove tests passed."