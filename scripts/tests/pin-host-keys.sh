#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for scripts/pin-host-keys.sh. NEVER probes live hosts: ssh-keyscan is
# replaced by a PATH stub that serves fixture scans from $FIXTURE_DIR
# ("<host>.<port>.scan"), and the script pins into a mktemp known_hosts via
# PIN_HOST_KEYS_KNOWN_HOSTS. Match fixtures are derived from the repo's own
# vendored sets (scripts/known-hosts.d/) so the suite can never drift from
# them. Everything lives under one mktemp root cleaned by an EXIT trap.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
SCRIPT="${PROJECT_DIR}/scripts/pin-host-keys.sh"
KNOWN_HOSTS_D="${PROJECT_DIR}/scripts/known-hosts.d"

SUITE_TMP=$(mktemp -d /tmp/sunbeam-pin-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

checks=0
ok() {
    echo "ok - $1"
    checks=$((checks + 1))
}

sum() {
    sha256sum "$1" | awk '{print $1}'
}

# --- stub ssh-keyscan: fixture-only, never touches the network -------------
STUB_BIN="${SUITE_TMP}/bin"
mkdir -p "$STUB_BIN"
cat > "${STUB_BIN}/ssh-keyscan" <<'EOF'
#!/bin/sh
# Test stub for scripts/tests/pin-host-keys.sh: serve
# "$FIXTURE_DIR/<host>.<port>.scan"; a missing fixture simulates a failed
# scan (network/DNS down).
port=22
host=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p) port="$2"; shift 2 ;;
        -T) shift 2 ;;
        --) shift ;;
        -*) shift ;;
        *) host="$1"; shift ;;
    esac
done
fixture="${FIXTURE_DIR:?stub ssh-keyscan needs FIXTURE_DIR}/${host}.${port}.scan"
if [ -f "$fixture" ]; then
    cat "$fixture"
else
    echo "stub ssh-keyscan: no fixture for ${host}:${port}" >&2
    exit 1
fi
EOF
chmod +x "${STUB_BIN}/ssh-keyscan"

[ "$(PATH="${STUB_BIN}:$PATH" command -v ssh-keyscan)" = "${STUB_BIN}/ssh-keyscan" ] \
    || fail "ssh-keyscan stub does not shadow the real binary"
ok "ssh-keyscan stub shadows the real binary (no live probing)"

CASE_DIR=""
FIXTURE_DIR=""
KH=""
new_case() {
    CASE_DIR=$(mktemp -d "${SUITE_TMP}/case.XXXXXX")
    FIXTURE_DIR="${CASE_DIR}/fixtures"
    KH="${CASE_DIR}/known_hosts"
    mkdir -p "$FIXTURE_DIR"
    : > "$KH"
}

# Match fixture for one endpoint, derived from the vendored set (keyscan
# output form is exactly "marker type key", like the vendored lines).
fixture_match() {
    grep -v '^#' "${KNOWN_HOSTS_D}/$1" > "${FIXTURE_DIR}/$1.$2.scan"
    printf '# %s:%s SSH-2.0-fixture\n' "$1" "$2" >> "${FIXTURE_DIR}/$1.$2.scan"
}

run_pin() {
    FIXTURE_DIR="$FIXTURE_DIR" PIN_HOST_KEYS_KNOWN_HOSTS="$KH" PATH="${STUB_BIN}:$PATH" \
        bash "$SCRIPT" "$1" 2>&1
}

# --- 1. matching scan appends exactly the vendored entries -----------------
new_case
fixture_match github.com 22
n_vendored=$(grep -vc '^#' "${KNOWN_HOSTS_D}/github.com")
out="$(run_pin github)" || fail "github match run failed: $out"
grep -q "github.com: pinned $n_vendored host key(s) (0 already present)" <<< "$out" \
    || fail "unexpected pin summary: $out"
diff <(grep -v '^#' "${KNOWN_HOSTS_D}/github.com" | sort) <(sort "$KH") >/dev/null \
    || fail "known_hosts content differs from the vendored set"
ok "matching scan appends the vendored github.com entries"

# --- 2. repeat run is a no-op (idempotency, not blind append) --------------
before=$(sum "$KH")
out="$(run_pin github)" || fail "github repeat run failed: $out"
grep -q "github.com: all $n_vendored host key(s) already pinned" <<< "$out" \
    || fail "repeat run did not report already-pinned: $out"
[ "$(sum "$KH")" = "$before" ] || fail "repeat run modified known_hosts"
ok "repeat run reports already-pinned and leaves known_hosts untouched"

# --- 3. mismatched scan aborts with nothing written -------------------------
new_case
fixture_match github.com 22
mitm_key=$(printf '%s' 'Intercepted MITM key' | base64)
sed -i "s|^github.com ssh-ed25519 .*|github.com ssh-ed25519 $mitm_key|" "${FIXTURE_DIR}/github.com.22.scan"
if out="$(run_pin github)"; then
    fail "mismatched scan unexpectedly succeeded: $out"
fi
grep -q "do not match the vendored set" <<< "$out" \
    || fail "missing MITM refusal in output: $out"
[ ! -s "$KH" ] || fail "mismatched scan run wrote to known_hosts"
ok "mismatched scan aborts non-zero without modifying known_hosts"

# --- 4. foreign pre-existing known_hosts entry aborts (trust guard) --------
new_case
fixture_match github.com 22
printf 'github.com ssh-ed25519 %s\n' "$mitm_key" > "$KH"
before=$(sum "$KH")
if out="$(run_pin github)"; then
    fail "foreign known_hosts entry unexpectedly accepted: $out"
fi
grep -q "does not publish" <<< "$out" || fail "missing foreign-key refusal: $out"
grep -q 'ssh-keygen -R' <<< "$out" || fail "missing remediation hint: $out"
[ "$(sum "$KH")" = "$before" ] || fail "trust-guard run modified known_hosts"
ok "foreign pre-existing entry aborts non-zero, known_hosts left as-is"

# --- 5. strict parsing of untrusted scan text ------------------------------
real_ed25519=$(awk '$2 == "ssh-ed25519" {print $3; exit}' "${KNOWN_HOSTS_D}/github.com")
bad_lines=(
    "github.com ssh-ed25519 ${real_ed25519} trailing-junk"
    "notgithub.com ssh-ed25519 ${real_ed25519}"
    "github.com ssh-rot13 ${real_ed25519}"
    "github.com ssh-ed25519 not+base64+ok+but+wrong%chars"
)
for bad in "${bad_lines[@]}"; do
    new_case
    fixture_match github.com 22
    grep -v ' ssh-ed25519 ' "${FIXTURE_DIR}/github.com.22.scan" > "${FIXTURE_DIR}/tmp"
    mv "${FIXTURE_DIR}/tmp" "${FIXTURE_DIR}/github.com.22.scan"
    printf '%s\n' "$bad" >> "${FIXTURE_DIR}/github.com.22.scan"
    if out="$(run_pin github)"; then
        fail "malformed scan accepted: $bad"
    fi
    grep -q "rejected" <<< "$out" || fail "no rejection message for '$bad': $out"
    [ ! -s "$KH" ] || fail "malformed scan run wrote to known_hosts"
done
ok "strict parser rejects extra fields, foreign hosts, unknown types, bad base64"

# --- 6. opendev bracketed [host]:port marker --------------------------------
new_case
fixture_match review.opendev.org 29418
out="$(run_pin opendev)" || fail "opendev match run failed: $out"
diff <(grep -v '^#' "${KNOWN_HOSTS_D}/review.opendev.org" | sort) <(sort "$KH") >/dev/null \
    || fail "known_hosts content differs from the vendored opendev set"
ssh-keygen -F '[review.opendev.org]:29418' -f "$KH" >/dev/null \
    || fail "ssh-keygen cannot find the pinned [review.opendev.org]:29418 entries"
ok "opendev gerrit keys pin under the [review.opendev.org]:29418 marker"

# --- 7. 'all' pins every forge ----------------------------------------------
new_case
fixture_match github.com 22
fixture_match review.opendev.org 29418
fixture_match git.launchpad.net 22
out="$(run_pin all)" || fail "'all' run failed: $out"
expected_total=$(cat "${KNOWN_HOSTS_D}/github.com" "${KNOWN_HOSTS_D}/review.opendev.org" "${KNOWN_HOSTS_D}/git.launchpad.net" | grep -vc '^#')
[ "$(wc -l < "$KH")" -eq "$expected_total" ] \
    || fail "'all' pinned $(wc -l < "$KH") entries, expected $expected_total"
grep -q "git.launchpad.net: pinned 1 host key(s)" <<< "$out" \
    || fail "launchpad summary missing from 'all' output: $out"
ok "'all' pins github, opendev and launchpad in one run"

# --- 8. failed scan aborts with nothing written ------------------------------
new_case
if out="$(run_pin github)"; then
    fail "missing fixture (scan failure) unexpectedly succeeded: $out"
fi
grep -q "ssh-keyscan of github.com failed" <<< "$out" \
    || fail "missing scan-failure message: $out"
[ ! -s "$KH" ] || fail "failed scan run wrote to known_hosts"
ok "failed scan aborts non-zero without modifying known_hosts"

# --- 9. usage errors ----------------------------------------------------------
rc=0
out="$(run_pin gitlab)" || rc=$?
[ "$rc" -eq 2 ] || fail "unknown forge exit code is $rc, want 2: $out"
grep -q "Usage:" <<< "$out" || fail "unknown forge printed no usage: $out"
ok "unknown forge exits 2 with usage"

echo ""
echo "PASS: pin-host-keys suite ($checks checks)"
