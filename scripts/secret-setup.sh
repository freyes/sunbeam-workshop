#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# secret-setup.sh [NAME] - store the GitHub token and the OpenRouter key in
# the HOST keyring and wire the gh-cli and openrouter secret plugs of a
# workshop instance (draft D-8, IS-7).
#
#   Usage: bash scripts/secret-setup.sh [NAME]
#     no NAME   only (1), (1b) and (2): keyring storage + host gh login
#     NAME      additionally (3) and (3b): connect NAME/gh-cli:github-token
#               to NAME/system:github-token and NAME/<profile>-tools:openrouter-key
#               to NAME/system:openrouter-key, then converge the opencode
#               auth inside the instance once it reports Ready
#
# Flow:
#   1. keyring: the PAT is stored once under
#      `secret-tool store service openstack-workshop-github-token` and looked
#      up from there on every re-run (idempotent repair).
#   1b. keyring (optional): the OpenRouter key is stored once under
#      `secret-tool store service openstack-workshop-openrouter-key`; the
#      prompt is skippable - empty input warns and CONTINUES (owner
#      decision: the key is optional; opencode stays unauthenticated until
#      one is stored).
#   2. host gh login: the rendered github-token secret slot reads gh's own
#      keyring login (service gh:github.com, current account). If gh is not
#      authenticated yet, the stored token is piped straight from the keyring
#      into `gh auth login --with-token` over stdin.
#   3. plug wiring: `workshop connect NAME/gh-cli:github-token
#      NAME/system:github-token`, skipped with a clear note when the
#      instance is not launched yet (guided setup runs this script before
#      `workshop launch`; it re-runs it after the instance is Ready).
#   3b. openrouter wiring + converger (BEST-EFFORT: the key is optional):
#      resolve the instance's profile via the vars module (the same
#      invocation scripts/render.sh uses), idempotently connect
#      NAME/<profile>-tools:openrouter-key to NAME/system:openrouter-key
#      (RUNTIME sdk name - the platform strips the `project-` prefix and
#      connection refs reject it), and when the instance reports Ready run
#      the shared writer inside it via `workshop exec` to converge
#      ~/.local/share/opencode/auth.json. No failure in this lane aborts
#      the run: an unconnectable plug - an instance launched from an
#      older definition predating the openrouter lane - or a failed
#      converger warns with the recovery and continues.
#
# THE GITHUB_TOKEN TRAP (ck8s-dev AGENTS.md rules 10-11):
#   * GITHUB_TOKEN and GH_TOKEN must NEVER be exported in the host shell or
#     the container environment: gh prefers them over its stored login, so a
#     stale or over-broad value silently overrides authentication and breaks
#     standard gh commands.
#   * The token and the OpenRouter key are NEVER printed (read -rs;
#     secret-tool and gh receive them only via stdin pipes) and NEVER
#     written to a file, the rendered yaml, or this repository: the
#     workshop definition carries keyring LOOKUP attributes, never the
#     value.
#
# Guard convention (IS-7): the just recipe wraps this script in assert-host;
# run directly it still refuses inside the workshop container (the workshop
# user has passwordless sudo there) unless I_KNOW_WHAT_IM_DOING=1.
set -euo pipefail

SERVICE="openstack-workshop-github-token"
LABEL="GitHub Personal Access Token (openstack-workshop)"
OR_SERVICE="openstack-workshop-openrouter-key"
OR_LABEL="OpenRouter API Key (openstack-workshop)"

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

# Workshop instance names are schema-bounded (scripts/openstack_workshop/vars.py).
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

# --- 1b. openrouter keyring storage (OPTIONAL: Enter skips) ---------------
# Mirrors the GitHub block above with ONE deliberate deviation (owner
# decision: the OpenRouter key is optional) - empty input warns and
# CONTINUES instead of aborting, so a workshop without a key still builds
# Ready and the key can be added later by re-running this script.
if secret-tool lookup service "$OR_SERVICE" >/dev/null 2>&1; then
    echo "✓ OpenRouter key already stored in the host keyring (service $OR_SERVICE)."
    echo "  Replace it with: secret-tool clear service $OR_SERVICE && just secret-setup"
else
    echo "Enter your OpenRouter API Key (input hidden, press Enter to skip)."
    echo "Create one at https://openrouter.ai/settings/keys"
    printf 'Key: '
    or_key=""
    read -rs or_key
    echo ""
    if [ -z "$or_key" ]; then
        echo "WARNING: no key entered; skipping the OpenRouter key - opencode will stay unauthenticated until you store one; re-run 'just secret-setup' to add it." >&2
    else
        printf '%s' "$or_key" | secret-tool store --label="$OR_LABEL" service "$OR_SERVICE"
        unset or_key
        echo "✓ OpenRouter key stored in the host keyring (service $OR_SERVICE)."
    fi
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

# --- 3b. openrouter plug wiring + post-Ready converger --------------------
# The openrouter secret plug never auto-connects (secret plugs are
# manual-only upstream), so wire it here and converge the opencode auth
# inside a Ready instance. The whole lane is BEST-EFFORT: the OpenRouter
# key is optional (step 1b skips), so no failure below may abort the
# guided setup. Every step degrades gracefully: an unresolvable profile
# or a not-yet-Ready instance skips with a note, an unconnectable plug or
# a failed converger warns with the recovery. The classic unconnectable
# case: the instance was launched from an older definition without the
# openrouter-key plug (the lane postdates the instance), so the platform
# refuses the connect with "SDK has no plug named openrouter-key" until
# the instance runs the current rendered definition (workshop refresh, or
# just remove + just setup for a fresh launch).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
profile="$( cd "$script_dir/.." && uv run --frozen --project "$script_dir" python -m openstack_workshop vars "$name" 2>/dev/null | jq -r '.profile // empty' )" || profile=""
if [ -z "$profile" ] || ! [[ "$profile" =~ ^[a-z0-9-]+$ ]]; then
    echo "WARNING: could not resolve the profile of '$name' via the vars module;" >&2
    echo "         skipping the openrouter plug wiring and the opencode auth converger." >&2
    exit 0
fi

or_plug="$name/${profile}-tools:openrouter-key"
or_slot="$name/system:openrouter-key"

if workshop connections "$name" 2>/dev/null | grep -qE "^[[:space:]]*secret[[:space:]]+${or_plug}[[:space:]]+${or_slot}[[:space:]]"; then
    echo "✓ $or_plug already connected to $or_slot."
elif workshop connect "$or_plug" "$or_slot"; then
    echo "✓ Connected $or_plug to $or_slot."
else
    echo "WARNING: could not connect $or_plug to $or_slot." >&2
    echo "         The instance was likely launched from an older definition without the" >&2
    echo "         openrouter-key plug (the openrouter lane postdates it); opencode stays" >&2
    echo "         unauthenticated inside '$name' until the instance runs the current rendered definition." >&2
    echo "         Recover: 'workshop refresh $name' (re-provisions from the current render," >&2
    echo "         discards the container writable layer), or 'just remove $name' then" >&2
    echo "         'just setup $name' for a fresh launch - then re-run 'just secret-setup $name'." >&2
    exit 0
fi

# The writer needs a live instance: converge only when Ready (the status
# parse mirrors scripts/setup.sh, quoted-value tolerant).
status="$(workshop info "$name" 2>/dev/null | awk '/^[[:space:]]*status:/ {print $2}' || true)"
status="${status#\"}"
status="${status%\"}"
case "$status" in
    [rR]eady)
        if workshop exec "$name" -- bash -c "set -euo pipefail; . /project/scripts/hooks/lib-common.sh && write_opencode_auth ${profile}-tools.openrouter-key"; then
            echo "✓ Converged the opencode auth inside '$name' (auth.json re-derived from the openrouter secret)."
        else
            echo "WARNING: the opencode auth converger failed inside '$name'; auth.json was not re-derived." >&2
            echo "         See docs/how-to/authenticate-opencode.rst (Troubleshooting): a locked host keyring or" >&2
            echo "         a corrupt auth.json is repaired there. The OpenRouter key is optional - the workshop" >&2
            echo "         stays Ready and healthy without opencode auth; re-run 'just secret-setup $name' after the fix." >&2
        fi
        ;;
    *)
        echo "⊘ Workshop '$name' is '${status:-not reporting a status yet}';"
        echo "  the opencode auth converger runs via 'just secret-setup $name' once the instance is Ready."
        ;;
esac
exit 0
