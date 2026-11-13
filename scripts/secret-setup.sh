#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# secret-setup.sh [NAME] - store the GitHub token in the HOST keyring and
# wire the gh-cli secret plug of a workshop instance (draft D-8, IS-7).
#
#   Usage: bash scripts/secret-setup.sh [NAME]
#     no NAME   only (1) and (2): keyring storage + host gh login
#     NAME      additionally (3): connect NAME/gh-cli:github-token to
#               NAME/system:github-token (the slot is declared by the
#               rendered .workshop/NAME.yaml; the connect form follows the
#               canonical/gh-cli-sdk README "Authenticate" section)
#
# Flow:
#   1. keyring: the PAT is stored once under
#      `secret-tool store service sunbeam-workshop-github-token` and looked
#      up from there on every re-run (idempotent repair).
#   2. host gh login: the rendered github-token secret slot reads gh's own
#      keyring login (service gh:github.com, current account). If gh is not
#      authenticated yet, the stored token is piped straight from the keyring
#      into `gh auth login --with-token` over stdin.
#   3. plug wiring: `workshop connect NAME/gh-cli:github-token
#      NAME/system:github-token`, skipped with a clear note when the
#      instance is not launched yet (guided setup runs this script before
#      `workshop launch`; it re-runs it after the instance is Ready).
#
# THE GITHUB_TOKEN TRAP (ck8s-dev AGENTS.md rules 10-11):
#   * GITHUB_TOKEN and GH_TOKEN must NEVER be exported in the host shell or
#     the container environment: gh prefers them over its stored login, so a
#     stale or over-broad value silently overrides authentication and breaks
#     standard gh commands.
#   * The token is NEVER printed (read -rs; secret-tool and gh receive it
#     only via stdin pipes) and NEVER written to a file, the rendered yaml,
#     or this repository: the workshop definition carries keyring LOOKUP
#     attributes, never the value.
#
# Guard convention (IS-7): the just recipe wraps this script in assert-host;
# run directly it still refuses inside the workshop container (the workshop
# user has passwordless sudo there) unless I_KNOW_WHAT_IM_DOING=1.
set -euo pipefail

SERVICE="sunbeam-workshop-github-token"
LABEL="GitHub Personal Access Token (sunbeam-workshop)"

# --- in-container refusal (mirrors the Justfile assert-host guard) ---
if [ "${I_KNOW_WHAT_IM_DOING:-0}" != "1" ] && [ "${USER:-}" = "workshop" ]; then
    echo "Error: assert-host: this command must be run from the host, not inside the Workshop." >&2
    echo "       Host keyring writes would otherwise run with the container's passwordless sudo." >&2
    echo "       Override with I_KNOW_WHAT_IM_DOING=1 to bypass." >&2
    exit 1
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -gt 1 ]; then
    echo "Usage: bash scripts/secret-setup.sh [NAME]" >&2
    echo "  NAME  workshop instance to wire (e.g. sunbeam, packaging-foo)." >&2
    echo "        Without NAME only the keyring storage and host gh login run." >&2
    [ $# -gt 1 ] && exit 2
    exit 0
fi
name="${1:-}"

# Workshop instance names are schema-bounded (scripts/sunbeam_workshop/vars.py).
if [ -n "$name" ] && { [ "${#name}" -gt 40 ] || ! [[ "$name" =~ ^[a-z](-?[a-z0-9])*$ ]]; }; then
    echo "ERROR: invalid instance name '$name' (want ^[a-z](-?[a-z0-9])*$, max 40 chars)." >&2
    exit 2
fi

if ! command -v secret-tool >/dev/null 2>&1; then
    echo "ERROR: 'secret-tool' is not installed. Install it with: sudo apt install -y libsecret-tools" >&2
    exit 1
fi

# --- 1. keyring storage ---------------------------------------------------
if secret-tool lookup service "$SERVICE" >/dev/null 2>&1; then
    echo "✓ GitHub token already stored in the host keyring (service $SERVICE)."
    echo "  Replace it with: secret-tool clear service $SERVICE && just secret-setup"
else
    echo "Enter your GitHub Personal Access Token (input hidden, press Enter to abort)."
    echo "Create one at https://github.com/settings/personal-access-tokens"
    printf 'Token: '
    token=""
    read -rs token
    echo ""
    if [ -z "$token" ]; then
        echo "ERROR: empty input; nothing stored." >&2
        exit 1
    fi
    printf '%s' "$token" | secret-tool store --label="$LABEL" service "$SERVICE"
    unset token
    echo "✓ GitHub token stored in the host keyring (service $SERVICE)."
fi

# --- 2. host gh login (the item the rendered secret slot reads) -----------
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: 'gh' is not installed on the host." >&2
    echo "       The rendered secret slot reads gh's keyring login (service gh:github.com)," >&2
    echo "       so the wiring cannot work without it. Install gh (https://cli.github.com)" >&2
    echo "       and re-run 'just secret-setup${name:+ $name}'." >&2
    exit 1
fi
if gh auth status >/dev/null 2>&1; then
    echo "✓ gh already authenticated on the host (the login the secret slot reads)."
else
    secret-tool lookup service "$SERVICE" | gh auth login --with-token
    echo "✓ gh authenticated on the host with the stored token."
fi

# --- 3. secret-plug wiring -------------------------------------------------
if [ -z "$name" ]; then
    echo ""
    echo "No instance name given; skipping the secret-plug wiring."
    echo "Run 'just secret-setup <name>' to wire <name>/gh-cli:github-token."
    exit 0
fi

if ! command -v workshop >/dev/null 2>&1; then
    echo "ERROR: the 'workshop' CLI is not installed; cannot wire the secret plug." >&2
    exit 1
fi

plug="$name/gh-cli:github-token"
slot="$name/system:github-token"

if ! workshop info "$name" >/dev/null 2>&1; then
    echo "⊘ Workshop '$name' is not launched yet; the keyring work above is done."
    echo "  The plug is wired after launch (guided setup re-runs this script once"
    echo "  the instance is Ready; or run 'just secret-setup $name' yourself)."
    exit 0
fi

if workshop connections "$name" 2>/dev/null | grep -qE "^[[:space:]]*secret[[:space:]]+${plug}[[:space:]]+${slot}[[:space:]]"; then
    echo "✓ $plug already connected to $slot."
else
    workshop connect "$plug" "$slot"
    echo "✓ Connected $plug to $slot."
fi
