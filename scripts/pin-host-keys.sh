#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# pin-host-keys.sh github|opendev|launchpad|all
#
# Pin SSH host keys for the forges the workshop pushes to in
# ~/.ssh/known_hosts, so git/ssh can run with StrictHostKeyChecking=yes
# instead of trusting whatever key the first connection presents.
# Generalized from ck8s-dev's scripts/pin-github-host-keys.sh to the three
# OpenStack forges (draft D-8). For each forge the script:
#
#   1. scans the forge's SSH endpoint with ssh-keyscan (-T 10 bounds every
#      connection attempt, so a hung network cannot block the run);
#   2. STRICTLY parses the scan (only the expected host marker, known key
#      types and base64 key material are accepted) and requires the scanned
#      set to equal the vendored set under scripts/known-hosts.d/ EXACTLY -
#      any difference aborts loudly: either the connection is intercepted
#      (MITM) or the forge rotated its keys, in which case the vendored file
#      may only be refreshed after out-of-band fingerprint verification
#      against the official source cited in its header;
#   3. refuses to keep any known_hosts entry for the endpoint that is not in
#      the vendored set - an earlier first-connection trust may have been
#      intercepted;
#   4. appends the vendored entries that are still missing. Idempotent: a
#      fully pinned endpoint is reported "already pinned" and left untouched.
#
# The vendored sets were verified against the official fingerprint pages
# cited in each file's header on 2026-11-13.
#
# Environment (used by scripts/tests/pin-host-keys.sh):
#   PIN_HOST_KEYS_KNOWN_HOSTS  target known_hosts file (default
#                              ~/.ssh/known_hosts). The test suite additionally
#                              stubs ssh-keyscan via PATH so no live host is
#                              ever probed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWN_HOSTS_D="$SCRIPT_DIR/known-hosts.d"

usage() {
    echo "Usage: bash scripts/pin-host-keys.sh github|opendev|launchpad|all" >&2
    exit 2
}

case "${1:-}" in
    github | opendev | launchpad | all) ;;
    *) usage ;;
esac

kh="${PIN_HOST_KEYS_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
mkdir -p "$(dirname "$kh")"
chmod 0700 "$(dirname "$kh")"
touch "$kh"

# endpoint table: name -> host, port, known_hosts marker
ep_host() {
    case "$1" in
        github) echo "github.com" ;;
        opendev) echo "review.opendev.org" ;;
        launchpad) echo "git.launchpad.net" ;;
        *) return 1 ;;
    esac
}

ep_port() {
    case "$1" in
        github) echo "22" ;;
        opendev) echo "29418" ;; # Gerrit's sshd; git-review's endpoint
        launchpad) echo "22" ;;
        *) return 1 ;;
    esac
}

ep_marker() {
    case "$1" in
        github) echo "github.com" ;;
        opendev) echo "[review.opendev.org]:29418" ;;
        launchpad) echo "git.launchpad.net" ;;
        *) return 1 ;;
    esac
}

# parse_entries EXPECTED-MARKER - strict known_hosts line parser (stdin ->
# stdout, one normalized "marker type key" line per entry). Comments and
# blank lines are skipped; anything else unexpected (field count, host
# marker, key type, non-base64 material) is REJECTED with an error, because
# the input is untrusted external text.
parse_entries() {
    local expected="$1"
    local line marker type key extra
    while IFS= read -r line; do
        case "$line" in
            "" | "#"*) continue ;;
        esac
        marker=""
        type=""
        key=""
        extra=""
        read -r marker type key extra <<< "$line"
        if [ -z "$marker" ] || [ -z "$type" ] || [ -z "$key" ] || [ -n "$extra" ]; then
            echo "ERROR: malformed known_hosts line rejected: '$line'" >&2
            return 1
        fi
        if [ "$marker" != "$expected" ]; then
            echo "ERROR: unexpected host '$marker' rejected (expected only '$expected')" >&2
            return 1
        fi
        case "$type" in
            ssh-rsa | ssh-dss | ssh-ed25519 | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521 | sk-ssh-ed25519@openssh.com | sk-ecdsa-sha2-nistp256@openssh.com) ;;
            *)
                echo "ERROR: unexpected key type '$type' rejected" >&2
                return 1
                ;;
        esac
        if ! [[ "$key" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
            echo "ERROR: non-base64 key material rejected" >&2
            return 1
        fi
        printf '%s %s %s\n' "$marker" "$type" "$key"
    done
}

pin_forge() {
    local ep="$1"
    local host port marker pinned_file
    host="$(ep_host "$ep")"
    port="$(ep_port "$ep")"
    marker="$(ep_marker "$ep")"
    pinned_file="$KNOWN_HOSTS_D/$host"
    if [ ! -f "$pinned_file" ]; then
        echo "ERROR: vendored known_hosts set missing: $pinned_file" >&2
        return 1
    fi

    local pinned scanned scan_out existing
    if ! pinned="$(parse_entries "$marker" < "$pinned_file" | sort -u)"; then
        echo "ERROR: $pinned_file failed strict parsing; refusing to trust it." >&2
        return 1
    fi
    if [ -z "$pinned" ]; then
        echo "ERROR: $pinned_file carries no usable keys." >&2
        return 1
    fi

    # 1. Scan the endpoint. -T 10 bounds each connection attempt.
    if ! scan_out="$(ssh-keyscan -T 10 -p "$port" "$host" 2>/dev/null)"; then
        echo "ERROR: ssh-keyscan of $marker failed (network, DNS or the host is down)." >&2
        return 1
    fi
    if ! scanned="$(parse_entries "$marker" <<< "$scan_out" | sort -u)"; then
        echo "ERROR: ssh-keyscan output for $marker failed strict parsing; refusing to trust it." >&2
        return 1
    fi
    if [ -z "$scanned" ]; then
        echo "ERROR: ssh-keyscan of $marker returned no usable keys." >&2
        return 1
    fi

    # 2. MITM guard: the endpoint must present exactly the vendored set.
    if [ "$scanned" != "$pinned" ]; then
        echo "ERROR: $marker presents SSH host keys that do not match the vendored set." >&2
        echo "       Either this connection is being intercepted (MITM) or the forge" >&2
        echo "       rotated its host keys. Do NOT bypass this check: re-vendor only" >&2
        echo "       after verifying the new fingerprints out-of-band against the" >&2
        echo "       official source cited in $pinned_file." >&2
        {
            echo "       presented but not vendored:"
            comm -13 <(printf '%s\n' "$pinned") <(printf '%s\n' "$scanned") | sed 's/^/         /'
            echo "       vendored but not presented:"
            comm -23 <(printf '%s\n' "$pinned") <(printf '%s\n' "$scanned") | sed 's/^/         /'
        } >&2
        return 1
    fi

    # 3. A known_hosts entry for this endpoint that is not vendored means an
    #    earlier first-connection trust may have been intercepted: refuse
    #    rather than keep trusting it. Compared as "type key" pairs so hashed
    #    known_hosts entries are covered too.
    existing="$(ssh-keygen -F "$marker" -f "$kh" 2>/dev/null | grep -v '^#' | awk '{print $2" "$3}' | sort -u || true)"
    local pinned_keys key
    pinned_keys="$(printf '%s\n' "$pinned" | awk '{print $2" "$3}')"
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        if ! grep -qxF "$key" <<< "$pinned_keys"; then
            echo "ERROR: $kh trusts a $marker ${key%% *} key that the vendored set does not publish." >&2
            echo "       An earlier first-connection trust may have been intercepted." >&2
            echo "       Remove it with 'ssh-keygen -R \"$marker\"' and re-run." >&2
            return 1
        fi
    done <<< "$existing"

    # 4. Append what is still missing; never duplicate (idempotent re-runs).
    local appended=0 present=0 entry
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if grep -qxF "${entry#* }" <<< "$existing"; then
            present=$((present + 1))
        else
            printf '%s\n' "$entry" >> "$kh"
            appended=$((appended + 1))
        fi
    done <<< "$pinned"
    if [ "$appended" -eq 0 ]; then
        echo "✓ $marker: all $present host key(s) already pinned"
    else
        echo "✓ $marker: pinned $appended host key(s) ($present already present)"
    fi
}

case "${1:-}" in
    github | opendev | launchpad)
        pin_forge "$1"
        ;;
    all)
        for ep in github opendev launchpad; do
            pin_forge "$ep"
        done
        ;;
    *)
        usage
        ;;
esac
