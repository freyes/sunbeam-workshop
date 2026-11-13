#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for scripts/check-just-shell.sh (awesome-multirepo scripts/tests
# pattern). The gate is copied into a FIXTURE repo tree in a mktemp root so
# the suite never depends on - or dirties - the real Justfile, just/ modules,
# and .workshop/ hook tree.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
GATE="${PROJECT_DIR}/scripts/check-just-shell.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# All fixture roots live under one suite tmp dir so the EXIT trap cleans up
# even when a test subshell fails mid-way.
SUITE_TMP=$(mktemp -d /tmp/sunbeam-check-just-shell-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

new_root() {
    mktemp -d "${SUITE_TMP}/root.XXXXXX"
}

# Fixture repo tree: the gate under test at scripts/check-just-shell.sh, a
# Justfile + one just/*.just module each carrying a clean shebang recipe, and
# .workshop/fixture-tools/hooks/ with one clean executable bash hook plus a
# non-shell payload file (mirrors the real tox-requirements.txt defect).
make_fixture() {
    local root=$1
    mkdir -p "${root}/scripts" "${root}/just" "${root}/.workshop/fixture-tools/hooks"
    cp "${GATE}" "${root}/scripts/check-just-shell.sh"
    cat > "${root}/Justfile" <<'EOF'
default:
    #!/usr/bin/env bash
    echo "hello from fixture"
EOF
    cat > "${root}/just/fixture.just" <<'EOF'
mod-recipe:
    #!/usr/bin/env bash
    echo "module recipe"
EOF
    cat > "${root}/.workshop/fixture-tools/hooks/good-hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "good hook"
EOF
    chmod +x "${root}/.workshop/fixture-tools/hooks/good-hook"
    cat > "${root}/.workshop/fixture-tools/hooks/tox-requirements.txt" <<'EOF'
tox==4.47.3 --hash=sha256:deadbeef
this ( is not shell and would fail SC2148/SC1097 if shellcheck ever saw it
EOF
}

test_txt_in_hooks_dir_is_skipped() (
    local root output
    root=$(new_root); make_fixture "${root}"
    output=$(bash "${root}/scripts/check-just-shell.sh") \
        || fail "gate failed on a fixture whose hooks dir carries a .txt payload: ${output}"
    [[ -f "${root}/.workshop/fixture-tools/hooks/tox-requirements.txt" ]] \
        || fail "fixture .txt vanished - the skip was not actually exercised."
)

test_bad_hook_still_fails_gate() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    cat > "${root}/.workshop/fixture-tools/hooks/bad-hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "this quote never ends
EOF
    chmod +x "${root}/.workshop/fixture-tools/hooks/bad-hook"
    set +e
    output=$(bash "${root}/scripts/check-just-shell.sh" 2>&1); status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "gate passed with a syntactically bad hook in the tree."
    grep -q "bad-hook" <<<"${output}" \
        || fail "gate output does not name the bad hook: ${output}"
)

test_non_executable_shell_file_is_skipped() (
    local root output
    root=$(new_root); make_fixture "${root}"
    cat > "${root}/.workshop/fixture-tools/hooks/notes.sh" <<'EOF'
#!/usr/bin/env bash
echo "this quote never ends
EOF
    output=$(bash "${root}/scripts/check-just-shell.sh") \
        || fail "gate failed on a non-executable .sh file in the hooks dir: ${output}"
)

test_file_list_form_clean_fixture() (
    local root output
    root=$(new_root); make_fixture "${root}"
    output=$(cd "${root}" && bash scripts/check-just-shell.sh Justfile just/*.just) \
        || fail "file-list form failed on the clean fixture: ${output}"
)

test_txt_in_hooks_dir_is_skipped
test_bad_hook_still_fails_gate
test_non_executable_shell_file_is_skipped
test_file_list_form_clean_fixture
echo "check-just-shell tests passed."
