#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# just doctor: read-only host diagnosis with detect-and-direct pointers
# (GAP-1; precedents: ck8s-dev Justfile doctor recipe; draft rows D-12,
# IS-10, A-15, A-16, A-1).
#
# Reports pass/warn/fail per check. Hard-fail (exit 1) ONLY on missing
# workshop or unusable LXD (missing client, unanswered daemon, or server
# older than 6.8, which Workshop requires). Everything else warns or
# informs. Exit code is 0 when no hard check failed, 1 otherwise.
#
# With the argument "sunbeam", additionally report the sidecar-VM capacity
# floor (cores >= 8, RAM >= 16 GiB, free disk >= 100 GiB) as WARN-only
# checks (A-15). Any other argument simply runs the base checks.
#
# READ-ONLY contract: this script installs nothing, writes no keyring
# entries, creates no files, and never prints secret values. Every probe
# that could block on a daemon or the network is wrapped in `timeout`.

# No `set -e`: every check is expected to be able to fail, and the summary
# at the end is the result.
set -uo pipefail

fails=0
warns=0

pass() { printf '✓ %s\n' "$1"; }
warn() {
    printf '⚠ %s\n' "$1"
    [ -n "${2:-}" ] && printf '  see: %s\n' "$2"
    warns=$((warns + 1))
}
fail() {
    printf '✗ %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf '  fix: %s\n' "$2" >&2
    fails=$((fails + 1))
}
info() { printf 'ℹ %s\n' "$1"; }

profile="${1:-}"
TUTORIAL="https://ubuntu.com/workshop/docs/tutorial/part-1-get-started/"

echo "Host prerequisites for sunbeam-workshop${profile:+ (profile: $profile)}:"

# --- Workshop snap (hard requirement) ---
if ! command -v workshop >/dev/null 2>&1; then
    fail "workshop is not on PATH" \
        "install the workshop snap per $TUTORIAL"
else
    workshop_version="$(timeout 10 workshop --version 2>/dev/null || true)"
    if [ -n "$workshop_version" ]; then
        pass "workshop installed ($workshop_version)"
    else
        warn "'workshop --version' returned nothing" "reinstall per $TUTORIAL"
    fi
fi

# --- LXD (hard requirement; Workshop requires server >= 6.8) ---
if ! command -v lxc >/dev/null 2>&1; then
    fail "lxc is not on PATH" \
        "set up LXD from the 6/stable channel per $TUTORIAL, then: sudo lxd init --minimal"
else
    lxd_version="$(timeout 8 lxc version 2>/dev/null | awk '/^Server version:/ {print $3}')"
    if [ -z "$lxd_version" ]; then
        fail "could not read the LXD server version; LXD is not initialised or not reachable" \
            "sudo lxd init --minimal"
    elif [ "$(printf '%s\n' 6.8 "$lxd_version" | sort -V | head -n1)" = "6.8" ]; then
        pass "LXD server $lxd_version (Workshop requires >= 6.8)"
    else
        fail "LXD server $lxd_version is older than 6.8, which Workshop requires" \
            "refresh LXD to the 6/stable channel per $TUTORIAL"
    fi
fi

# --- Tooling on PATH (warn-only) ---
for cmd in just uv git jq yq; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "$cmd on PATH"
    else
        warn "$cmd is not on PATH" "host prerequisites: $TUTORIAL"
    fi
done

# --- secret-tool (warn-only; the probe tolerates an absent entry) ---
if ! command -v secret-tool >/dev/null 2>&1; then
    warn "secret-tool is not on PATH; the keyring flow needs it" \
        "host prerequisites: $TUTORIAL"
else
    # Probe with a harmless lookup. The looked-up value (if any) goes to
    # /dev/null and is never read, stored, or printed.
    probe_err="$(timeout 5 secret-tool lookup service sunbeam-workshop-probe 2>&1 >/dev/null)"
    probe_rc=$?
    if [ "$probe_rc" -eq 124 ]; then
        warn "secret-tool probe timed out after 5s" \
            "check the secret-service daemon: $TUTORIAL"
    elif [ "$probe_rc" -eq 0 ]; then
        pass "secret-tool can query the secret service"
    elif [ -z "$probe_err" ]; then
        pass "secret-tool usable (probe entry absent, which is tolerated)"
    else
        warn "secret-tool probe failed: $(printf '%s\n' "$probe_err" | head -n1)" \
            "secret-service setup: $TUTORIAL"
    fi
fi

# --- Host architecture (A-15: amd64 supported, arm64 best-effort) ---
case "$(uname -m)" in
    x86_64)
        pass "host arch amd64 (supported, A-15)"
        ;;
    aarch64 | arm64)
        warn "host arch arm64 is best-effort only (A-15)"
        ;;
    *)
        warn "host arch $(uname -m) is untested; A-15 supports amd64"
        ;;
esac

# --- sunbeam profile capacity floor (warn-only, A-15) ---
if [ "$profile" = "sunbeam" ]; then
    echo ""
    echo "Capacity for the sunbeam profile (warn-only, A-15):"

    cores="$(nproc 2>/dev/null || printf '0')"
    if [ "$cores" -ge 8 ]; then
        pass "host has $cores vCPU; the sunbeam sidecar VM wants >= 8"
    else
        warn "host has $cores vCPU but the sunbeam sidecar VM wants >= 8"
    fi

    mem_gib=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || printf '0') / 1048576))
    if [ "$mem_gib" -ge 16 ]; then
        pass "host has ${mem_gib}GiB RAM; the sunbeam sidecar VM wants >= 16GiB"
    else
        warn "host has ${mem_gib}GiB RAM but the sunbeam sidecar VM wants >= 16GiB"
    fi

    pool_fs=/var/snap/lxd
    [ -d "$pool_fs" ] || pool_fs=/
    free_gib="$(df -BG --output=avail "$pool_fs" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    [ -n "$free_gib" ] || free_gib=0
    if [ "$free_gib" -ge 100 ]; then
        pass "${free_gib}GiB free on $pool_fs; the sunbeam sidecar VM wants >= 100GiB"
    else
        warn "only ${free_gib}GiB free on $pool_fs but the sunbeam sidecar VM wants >= 100GiB"
    fi
fi

# --- External accounts: detect-and-direct (no probing of external services) ---
echo ""
echo "External accounts (detect-and-direct; remote services are not probed):"

if ! command -v gh >/dev/null 2>&1; then
    warn "gh is not on PATH; GitHub authentication cannot be checked" \
        "https://cli.github.com then: gh auth login"
elif timeout 8 gh auth status >/dev/null 2>&1; then
    pass "gh is authenticated on the host"
else
    warn "gh is not authenticated on the host" \
        "create a token per https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token then: gh auth login"
fi

if compgen -G "$HOME/.ssh/*.pub" >/dev/null 2>&1; then
    pass "ssh public key(s) present under ~/.ssh"
else
    warn "no ssh public key under ~/.ssh; Gerrit and Launchpad uploads need one" \
        "Gerrit: https://docs.opendev.org/opendev/infra-manual/latest/gettingstarted.html ; Launchpad: https://help.launchpad.net/YourAccount/CreatingAnSSHKeyPair"
fi

info "prerequisite: Ubuntu One account (https://login.ubuntu.com) and signed Canonical ICLA (https://ubuntu.com/legal/contributors)"
info "prerequisite (A-16): Atlassian Cloud access for the Jira MCP server (https://id.atlassian.com) plus metered LLM spend"

# --- Locally installed workshop SDKs / snap revisions (A-1/A-3 drift surface) ---
echo ""
echo "Revisions (A-1/A-3 drift surface):"
if command -v sdk >/dev/null 2>&1; then
    sdk_out="$(timeout 10 sdk list 2>&1 || true)"
    if [ -n "$sdk_out" ]; then
        printf '%s\n' "$sdk_out" | while IFS= read -r line; do info "sdk: $line"; done
    else
        info "'sdk list' returned nothing"
    fi
else
    info "no 'sdk' command on PATH; workshop SDK revision report skipped"
fi
if command -v snap >/dev/null 2>&1; then
    snap_out="$(timeout 8 snap list workshop lxd 2>/dev/null || true)"
    if [ -n "$snap_out" ]; then
        printf '%s\n' "$snap_out" | while IFS= read -r line; do info "snap: $line"; done
    else
        info "snap list reports neither workshop nor lxd"
    fi
fi

# --- Summary ---
echo ""
if [ "$fails" -gt 0 ]; then
    echo "✗ $fails hard prerequisite(s) not satisfied. Fix the items above and re-run 'just doctor'." >&2
    exit 1
fi
if [ "$warns" -gt 0 ]; then
    echo "✓ host can run sunbeam-workshop ($warns warning(s) above)"
else
    echo "✓ host can run sunbeam-workshop"
fi
exit 0
