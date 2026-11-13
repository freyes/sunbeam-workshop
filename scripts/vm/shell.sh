#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# shell.sh - open an interactive ssh shell on the sunbeam sidecar dev VM, as
# the dev user. The host key was captured out of band via the LXD agent at
# create time, so StrictHostKeyChecking stays on.
#
#   Usage: bash scripts/vm/shell.sh       (usually via `just vm-shell`)
#
# SUNBEAM_WORKSHOP_ROOT overrides the repo root (fixture tests use it).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "${SUNBEAM_WORKSHOP_ROOT:-$SCRIPT_DIR/../..}" >/dev/null 2>&1 && pwd -P)"
# shellcheck source=scripts/vm/lib-vm.sh
source "$SCRIPT_DIR/lib-vm.sh"

if [ ! -f "$VM_IP_FILE" ]; then
    vm_die "no sidecar VM recorded ($VM_IP_FILE is missing). Run 'just vm-create' first."
fi
if [ ! -f "$VM_KEY" ]; then
    vm_die "no SSH keypair ($VM_KEY is missing). Run 'just vm-create' first."
fi

addr="$(cat "$VM_IP_FILE")"
exec ssh -t -i "$VM_KEY" -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$VM_KNOWN_HOSTS" \
    "dev@$addr"
