#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# setup.sh - guided end-to-end setup of a named OpenStack workshop instance.
#
#   Usage: bash scripts/setup.sh NAME        (NAME e.g. sunbeam, packaging-foo)
#
# Flow (modeled on the ck8s-dev Justfile guided setup):
#   1. scripts/doctor.sh                  read-only host prerequisite checks
#   2. confirm                            SETUP_YES=1 takes every default
#   3. scripts/render.sh NAME             render .workshop/<name>.yaml
#   4. persist the merged vars doc        .state/<name>.vars.json (mode 0600)
#   5. scripts/secret-setup.sh NAME       host keyring + gh-cli secret plug
#   6. workshop launch <name>             then wait for SDK health (Ready)
#
# Every step is idempotent: re-running repairs an interrupted setup instead of
# starting over. The trap says exactly which step stopped so the fix is one
# command away.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TOTAL_STEPS=6
current_step=0
current_title="startup"

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: bash scripts/setup.sh NAME" >&2
    echo "  NAME  workshop instance name: a profile (sunbeam, charmed, packaging)" >&2
    echo "        or a suffixed instance of one (e.g. packaging-foo)." >&2
    [ "${1:-}" = "" ] && exit 2 || exit 0
fi
name="$1"

banner() {
    current_step="$1"
    current_title="$2"
    echo ""
    echo "───────────────────────────────────────────────────"
    echo "Step $1/$TOTAL_STEPS · $2"
    echo "───────────────────────────────────────────────────"
}

# A bare `error: Recipe failed` says nothing about where the walkthrough
# got to, and the whole point of these steps is that you can resume.
on_error() {
    echo "" >&2
    echo "Setup stopped in step $current_step/$TOTAL_STEPS ($current_title)." >&2
    echo "Fix the error above and re-run 'just setup $name': completed steps are skipped." >&2
}
trap on_error ERR

# Every prompt goes through here. SETUP_YES=1 and a non-interactive
# stdin both fall back to the stated default instead of blocking.
confirm() {
    local prompt="$1"
    local default="$2"
    local hint="y/N"
    local reply=""
    if [ "$default" = "y" ]; then
        hint="Y/n"
    fi
    printf '%s [%s] ' "$prompt" "$hint"
    if [ "${SETUP_YES:-0}" = "1" ]; then
        echo "→ $default (SETUP_YES=1)"
        reply="$default"
    elif ! read -r reply; then
        echo ""
        echo "  no answer available on stdin; taking the default ($default)"
        reply="$default"
    fi
    case "${reply:-$default}" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

require_script() {
    if [ ! -f "$1" ]; then
        echo "Error: $1 is missing; it is provided by a later work item." >&2
        echo "       Land it (or check out the full repo) and re-run 'just setup $name'." >&2
        exit 1
    fi
}

# Wait until `workshop info <name>` reports status Ready - the platform's
# health signal, which already aggregates the SDK check-health hooks.
wait_ready() {
    local i info_out=""
    for i in $(seq 1 12); do
        info_out="$(workshop info "$name" 2>&1)" || true
        if printf '%s\n' "$info_out" | grep -qiE '^[[:space:]]*status:[[:space:]]*"?ready"?[[:space:]]*$'; then
            printf '%s\n' "$info_out"
            return 0
        fi
        echo "    ... not Ready yet (attempt $i/12), sleeping 10s"
        sleep 10
    done
    echo "ERROR: workshop '$name' did not reach status Ready; last 'workshop info $name' output:" >&2
    printf '%s\n' "$info_out" >&2
    return 1
}

echo "sunbeam-workshop guided setup of '$name': $TOTAL_STEPS steps, each idempotent"
echo "and safe to re-run. SETUP_YES=1 takes every default."

banner 1 "Host checks"
echo "Read-only check of everything the remaining steps depend on."
require_script scripts/doctor.sh
if ! bash scripts/doctor.sh "$name"; then
    echo ""
    echo "Setup stopped at step 1: the host is not ready yet." >&2
    echo "Fix the items above, then re-run 'just setup $name' - completed steps are skipped." >&2
    exit 1
fi

banner 2 "Confirm"
echo "The remaining steps render .workshop/$name.yaml, write the merged"
echo "variables to .state/, store credentials in the host keyring, and launch"
echo "the '$name' workshop container."
if ! confirm "Proceed with the guided setup of '$name'?" y; then
    echo "⊘ Aborted before making any changes."
    exit 0
fi

banner 3 "Render workshop definition"
echo "Renders .workshop/$name.yaml from the profile template and merged vars."
require_script scripts/render.sh
bash scripts/render.sh "$name"

banner 4 "Persist merged variables"
echo "Writes the merged vars doc to .state/$name.vars.json (mode 0600)."
mkdir -p .state
chmod 0700 .state
vars_tmp=".state/.$name.vars.json.tmp"
vars_file=".state/$name.vars.json"
( cd scripts && uv run --frozen python -m sunbeam_workshop vars "$name" ) > "$vars_tmp"
mv "$vars_tmp" "$vars_file"
chmod 0600 "$vars_file"
echo "✓ Wrote $vars_file"

banner 5 "Secrets"
echo "Stores the GitHub token in the host keyring and wires the gh-cli plug."
require_script scripts/secret-setup.sh
bash scripts/secret-setup.sh "$name"

banner 6 "Workshop container"
echo "Launches the '$name' workshop container and waits for SDK health."
status="$(workshop info "$name" 2>/dev/null | awk '/^[[:space:]]*status:/ {print $2}' || true)"
# Tolerate a quoted status value the way wait_ready already does.
status="${status#\"}"
status="${status%\"}"
case "$status" in
    [rR]eady)
        echo "✓ Workshop '$name' already active. Skipping launch."
        ;;
    "")
        echo "✓ Launching the '$name' workshop environment..."
        workshop launch --verbose "$name"
        ;;
    *)
        echo "✓ Workshop '$name' exists but is '$status'. Starting it..."
        workshop start "$name"
        ;;
esac
wait_ready

# The gh-cli secret plug is a manual connection and the instance did not
# exist when step 5 ran, so wire it now. secret-setup.sh is idempotent: the
# keyring steps report already-done and only the connect is new.
echo "Wiring the gh-cli secret plug (idempotent re-run of the secrets step)."
bash scripts/secret-setup.sh "$name"

# The repos hint names the resolved profile: first-dash truncation of the
# instance name is wrong for dashed profile names, so resolve via the vars
# module (longest-prefix).
profile="$(cd scripts && uv run --frozen python -m sunbeam_workshop vars "$name" | jq -r .profile)"
echo ""
echo "════════════════════════════════════════════════════"
echo "Setup complete - workshop '$name' is ready."
echo "════════════════════════════════════════════════════"
echo "  just shell $name      shell in the workshop container"
echo "  just stop $name       stop the workshop container"
echo "  just remove $name     remove the workshop container"
echo "  just repos $profile    clone/update its repositories"
echo "  just                  list every available command"
echo ""
