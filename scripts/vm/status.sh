#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# status.sh - report the sunbeam sidecar dev VM state. READ-ONLY: probes the
# host LXD and the recorded .state/vm material, writes nothing. Exits 0 when
# the VM is RUNNING and the recorded state is coherent, 1 otherwise.
#
#   Usage: bash scripts/vm/status.sh      (usually via `just vm-status`)
#
# SUNBEAM_WORKSHOP_ROOT overrides the repo root (fixture tests use it).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "${SUNBEAM_WORKSHOP_ROOT:-$SCRIPT_DIR/../..}" >/dev/null 2>&1 && pwd -P)"
# shellcheck source=scripts/vm/lib-vm.sh
source "$SCRIPT_DIR/lib-vm.sh"

vm_load_config

fail=0

if ! command -v lxc >/dev/null 2>&1; then
    echo "✗ 'lxc' is not on PATH; the sidecar VM state cannot be determined." >&2
    exit 1
fi

state="$(lxc list "$VM_NAME" --format json 2>/dev/null | jq -r '(.[0].status // empty) | ascii_upcase')"
case "$state" in
    RUNNING)
        echo "✓ VM $VM_NAME is RUNNING"
        ;;
    "")
        echo "✗ VM $VM_NAME is absent. Run 'just vm-create'." >&2
        exit 1
        ;;
    *)
        echo "✗ VM $VM_NAME is $state, expected RUNNING. Run 'just vm-create' to start it." >&2
        exit 1
        ;;
esac

if timeout 30 lxc exec "$VM_NAME" -- test -e "$VM_MARKER"; then
    echo "✓ provisioning marker $VM_MARKER present"
else
    echo "✗ $VM_MARKER missing: provisioning did not complete." >&2
    echo "  Recreate with 'just vm-destroy && just vm-create'." >&2
    fail=1
fi

addr="$(vm_addr "$VM_NAME")"
cached="$(cat "$VM_IP_FILE" 2>/dev/null || true)"
if [ "$addr" = "$cached" ]; then
    echo "✓ recorded address matches the live address ($addr)"
else
    echo "✗ recorded address is '${cached:-none}' but the VM is at '$addr'." >&2
    echo "  The DHCP lease changed. Re-run 'just vm-create' to re-point everything." >&2
    fail=1
fi

if [ -f "$VM_KEY" ] && [ -f "$VM_KEY.pub" ]; then
    echo "✓ ssh keypair present in $VM_STATE"
else
    echo "✗ ssh keypair missing in $VM_STATE. Run 'just vm-create'." >&2
    fail=1
fi

if [ -f "$VM_FP_FILE" ]; then
    recorded="$(tr -d '[:space:]' < "$VM_FP_FILE")"
    live="$(lxc exec "$VM_NAME" -- lxc config trust list --format json \
        | jq -r '.[] | select(.name=="sunbeam-workshop") | .fingerprint')"
    if [ "$recorded" = "$live" ]; then
        echo "✓ recorded trust fingerprint matches the VM's trust store"
    else
        echo "✗ recorded fingerprint does not match the VM's trust store." >&2
        echo "  recorded=$recorded live=$live - re-run 'just vm-create'." >&2
        fail=1
    fi
else
    echo "✗ $VM_FP_FILE missing. Run 'just vm-create'." >&2
    fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "✓ sidecar VM status OK"
