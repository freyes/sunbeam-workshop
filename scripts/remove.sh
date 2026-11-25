#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# remove.sh - remove a named workshop instance definition.
#
#   Usage: bash scripts/remove.sh NAME     (usually via `just remove NAME`)
#
# `workshop remove` only handles instances the platform has launched: it
# refuses a NAME whose rendered definition exists but whose container was
# never created ("workshop not launched"). A rendered .workshop/<NAME>.yaml
# is this repo's definition of the instance, so removing an unlaunched
# instance means deleting that rendered definition:
#
#   1. pass NAME through to `workshop remove` - success removes a launched
#      instance's container exactly as before
#   2. on the "workshop not launched" refusal, with a rendered definition
#      present, delete the definition and report it removed
#   3. every other failure (unknown NAME, LXD down, ...) propagates its
#      output and exit code unchanged - nothing is masked or cleaned up
#
# OPENSTACK_WORKSHOP_ROOT overrides the repo root (the test-suite fixture
# roots use it; the definition path resolves under the overridden root).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "${OPENSTACK_WORKSHOP_ROOT:-$SCRIPT_DIR/..}" >/dev/null 2>&1 && pwd -P)"

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: bash scripts/remove.sh NAME" >&2
    echo "  NAME  workshop instance name: a profile (sunbeam, charmed, packaging)" >&2
    echo "        or a suffixed instance of one (e.g. packaging-foo)." >&2
    [ "${1:-}" = "" ] && exit 2 || exit 0
fi
name="$1"
definition="$ROOT/.workshop/$name.yaml"

# 1. Launched instances: plain passthrough. The output is re-emitted so the
# caller sees exactly what `workshop remove` printed (exit code preserved).
remove_out=""
remove_rc=0
remove_out="$(workshop remove "$name" 2>&1)" || remove_rc=$?
if [ "$remove_rc" -eq 0 ]; then
    printf '%s\n' "$remove_out"
    exit 0
fi

# 2. The "not launched" refusal with a rendered definition present: the
# instance never existed beyond its definition, so removing it means
# deleting the definition.
if [ -f "$definition" ] && printf '%s\n' "$remove_out" | grep -qi 'not launched'; then
    rm -f -- "$definition"
    echo "✓ Removed rendered definition $definition (workshop '$name' was never launched)."
    exit 0
fi

# 3. Every other failure: unchanged output and exit code.
printf '%s\n' "$remove_out" >&2
exit "$remove_rc"