#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# destroy.sh - tear down the sunbeam sidecar dev VM (guarded, IS-7).
#
#   Usage: bash scripts/vm/destroy.sh     (usually via `just vm-destroy`)
#     YES=1    skip the interactive type-the-name confirmation
#     PURGE=1  also remove .state/vm/ (default: preserved, keypair retained
#              so a recreate stays idempotent)
#
# Happy-path order (ported from ck8s-dev):
#   1. host guard + validate config/vm.json
#   2. refuse when there is no recorded state (no .state/vm keypair)
#   3. confirm (interactive; YES=1 for non-interactive)
#   4. revoke the LXD trust certificate SERVER-SIDE on the VM - a client-side
#      `lxc remote remove` is NOT revocation, and no trust material may be
#      left behind after destroy
#   5. lxc delete -f the VM, drop ip/known_hosts/token/fingerprint records
#
# SUNBEAM_WORKSHOP_ROOT overrides the repo root (fixture tests use it).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "${SUNBEAM_WORKSHOP_ROOT:-$SCRIPT_DIR/../..}" >/dev/null 2>&1 && pwd -P)"
# shellcheck source=scripts/vm/lib-vm.sh
source "$SCRIPT_DIR/lib-vm.sh"

vm_guard_host
vm_load_config

# No recorded state means this tooling never created (or already purged) the
# VM here; there is nothing to confirm, revoke or delete.
if [ ! -f "$VM_KEY" ]; then
    vm_die "no sidecar VM state: $VM_KEY is missing.
       Either the VM was never created (just vm-create) or .state was purged.
       If a stray VM exists on the host, remove it with: lxc delete -f $VM_NAME"
fi

if [ "${YES:-0}" != "1" ]; then
    reply=""
    if [ -t 0 ]; then
        read -r -p "Destroy sidecar VM '$VM_NAME' and revoke its LXD trust? Type '$VM_NAME' to confirm: " reply
    fi
    if [ "$reply" != "$VM_NAME" ]; then
        vm_die "confirmation did not match '$VM_NAME' (non-interactive shells: set YES=1). Aborting."
    fi
fi

# Best effort: deleting the VM destroys its LXD database, and with it the
# trust store, so a failed revocation must not block teardown. This script
# succeeds only if the VM is actually gone.
vm_revoke_trust || \
    echo "Warning: revocation failed; proceeding, VM deletion removes its trust store." >&2

if lxc info "$VM_NAME" >/dev/null 2>&1; then
    echo "Deleting sidecar VM $VM_NAME..."
    lxc delete -f "$VM_NAME"
else
    echo "✓ VM $VM_NAME does not exist. Nothing to delete."
fi

rm -f "$VM_IP_FILE" "$VM_KNOWN_HOSTS" "$VM_TOKEN_FILE" "$VM_FP_FILE"

if [ "${PURGE:-0}" = "1" ]; then
    rm -rf "$VM_STATE"
    echo "✓ VM removed and $VM_STATE purged (PURGE=1)."
else
    echo "✓ VM removed and trust state cleared. Keypair kept in $VM_STATE (purge everything with PURGE=1)."
fi
