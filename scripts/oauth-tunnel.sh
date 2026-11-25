#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# oauth-tunnel.sh - wire or unwire the MCP OAuth callback tunnel of a named
# workshop instance, on demand.
#
#   Usage: bash scripts/oauth-tunnel.sh {connect|disconnect} NAME
#     (usually via `just connect NAME` / `just disconnect NAME`)
#
# The rendered definition declares the system tunnel plug
# (system:mcp-oauth-callback, endpoint localhost:19876) but deliberately
# does NOT connect it to the opencode SDK's opencode-mcp-oauth-callback
# slot: forwarding host loopback into the workshop is opt-in, not a
# launch-time auto-connect. This script is the on-demand switch:
#
#   connect     `workshop connect NAME/system:mcp-oauth-callback
#                NAME/opencode:opencode-mcp-oauth-callback`
#   disconnect  `workshop disconnect` with the same pair
#
# Both verbs are idempotent: an already-wired pair skips the connect, an
# unwired pair skips the disconnect. A runtime manual connection survives
# `workshop refresh` (the plug and the slot still exist in the definition)
# but is dropped by `workshop restore` - re-run `just connect NAME` after a
# restore.
#
# NAME must be a LAUNCHED instance: the wiring needs a live workshop. The
# script refuses (mirroring scripts/secret-setup.sh) when `workshop info`
# does not answer for the instance.
set -euo pipefail

plug="system:mcp-oauth-callback"
slot="opencode:opencode-mcp-oauth-callback"

usage() {
    echo "Usage: bash scripts/oauth-tunnel.sh {connect|disconnect} NAME" >&2
    echo "  connect     wire NAME/$plug to NAME/$slot (the OAuth consent tunnel)" >&2
    echo "  disconnect  unwire the pair again" >&2
    echo "  NAME        workshop instance name (e.g. sunbeam, packaging-foo)" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ $# -ne 2 ]; then
    usage
    exit 2
fi
verb="$1"
name="$2"

case "$verb" in
    connect|disconnect) ;;
    *)
        echo "ERROR: unknown verb '$verb' (want connect or disconnect)." >&2
        usage
        exit 2
        ;;
esac

# Workshop instance names are schema-bounded (scripts/openstack_workshop/vars.py).
if [ "${#name}" -gt 40 ] || ! [[ "$name" =~ ^[a-z](-?[a-z0-9])*$ ]]; then
    echo "ERROR: invalid instance name '$name' (want ^[a-z](-?[a-z0-9])*$, max 40 chars)." >&2
    exit 2
fi

if ! command -v workshop >/dev/null 2>&1; then
    echo "ERROR: the 'workshop' CLI is not installed; cannot wire the tunnel pair." >&2
    exit 1
fi

if ! workshop info "$name" >/dev/null 2>&1; then
    echo "ERROR: workshop '$name' is not launched; the tunnel pair is wired on a" >&2
    echo "       running instance. Launch it first: just launch $name" >&2
    exit 1
fi

# A `workshop connections` row reads <interface>\t<plug>\t<slot>\t<notes>; the
# same tolerant [[:space:]]+ row pattern scripts/secret-setup.sh greps. NAME
# is [a-z0-9-] only, so interpolating it into the row regex is safe.
row_re="^[[:space:]]*tunnel[[:space:]]+${name}/${plug}[[:space:]]+${name}/${slot}[[:space:]]"

case "$verb" in
    connect)
        if workshop connections "$name" 2>/dev/null | grep -qE "$row_re"; then
            echo "✓ ${name}/${plug} already connected to ${name}/${slot}."
        else
            workshop connect "${name}/${plug}" "${name}/${slot}"
            echo "✓ Connected ${name}/${plug} to ${name}/${slot} (manual connection)."
            echo "  Unwire it again with: just disconnect $name"
        fi
        ;;
    disconnect)
        if workshop connections "$name" 2>/dev/null | grep -qE "$row_re"; then
            workshop disconnect "${name}/${plug}" "${name}/${slot}"
            echo "✓ Disconnected ${name}/${plug} from ${name}/${slot}."
        else
            echo "✓ ${name}/${plug} is not connected to ${name}/${slot} - nothing to do."
        fi
        ;;
esac