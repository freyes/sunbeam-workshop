#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# create.sh - create the sunbeam sidecar dev VM (draft D-11): an LXD VM on the
# host running the craft toolchain, microk8s and juju for func/deployment
# testing. Idempotent: re-running repairs a stopped VM instead of recreating.
#
#   Usage: bash scripts/vm/create.sh      (usually via `just vm-create`)
#
# Flow (ported from ck8s-dev just/vm.just):
#   1. host guard + validate config/vm.json
#   2. ssh keypair in .state/vm/ (mode 0600), generated once, kept on destroy
#   3. render cloud-init fresh from the merged vars doc + pubkey
#   4. lxc init/start (== `lxc launch ubuntu:26.04 --vm` with user-data piped
#      between init and start, so a failed injection cannot leave a partial VM)
#   5. wait for agent + cloud-init + provisioning marker (bounded)
#   6. record address + host key, then set up the LXD remote server-side:
#      listener on <addr>:8443, 1H token expiry, mint a restricted token and
#      record its 64-hex fingerprint for destroy-time revocation
#
# OPENSTACK_WORKSHOP_ROOT overrides the repo root (fixture tests use it).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "${OPENSTACK_WORKSHOP_ROOT:-$SCRIPT_DIR/../..}" >/dev/null 2>&1 && pwd -P)"
# shellcheck source=scripts/vm/lib-vm.sh
source "$SCRIPT_DIR/lib-vm.sh"

vm_guard_host
vm_load_config

if ! command -v lxc >/dev/null 2>&1; then
    vm_die "'lxc' was not found on PATH; a working LXD is required (sudo snap install lxd --channel=6/stable && sudo lxd init --minimal)."
fi

if ! lxc storage show "$VM_POOL" >/dev/null 2>&1; then
    vm_die "LXD storage pool '$VM_POOL' does not exist on this host (have: $(lxc storage list --format csv | cut -d, -f1 | paste -sd' ')). Set .pool in config/vm.json."
fi

# .state/vm holds credentials-adjacent material (keypair, token): 0700/0600.
umask 077
mkdir -p "$VM_STATE"
chmod 0700 "$ROOT/.state" "$VM_STATE"
if [ ! -f "$VM_KEY" ]; then
    echo "Generating SSH keypair for the sidecar VM..."
    ssh-keygen -t ed25519 -f "$VM_KEY" -N "" -C "openstack-workshop@$VM_NAME"
fi
chmod 0600 "$VM_KEY"

# Render cloud-init FRESH from the merged vars doc on every run: pin bumps in
# profiles/sunbeam/vars.json must take effect on the next create, never serve
# a cached render. vm_pubkey rides along inside the vars JSON (one render
# path: scripts/jinja2).
VARS_TMP=""
RENDER_TMP=""
cleanup() {
    [ -z "$VARS_TMP" ] || rm -f -- "$VARS_TMP"
    [ -z "$RENDER_TMP" ] || rm -f -- "$RENDER_TMP"
}
trap cleanup EXIT
VARS_TMP="$(mktemp --suffix=.json)"
RENDER_TMP="$(mktemp --suffix=.yaml)"
( cd "$ROOT" && uv run --frozen --project "$ROOT/scripts" python -m openstack_workshop vars sunbeam ) > "$VARS_TMP"
jq --arg k "$(cat "$VM_KEY.pub")" '. + {vm_pubkey: $k}' "$VARS_TMP" > "$VARS_TMP.merged"
mv -f -- "$VARS_TMP.merged" "$VARS_TMP"
"$ROOT/scripts/jinja2" "$ROOT/scripts/vm/cloud-init.yaml.j2" "$VARS_TMP" > "$RENDER_TMP"

# `--format json` reports "Running" while `--format csv` reports "RUNNING";
# upper-case the value so the comparison cannot depend on that difference.
state="$(lxc list "$VM_NAME" --format json 2>/dev/null | jq -r '(.[0].status // empty) | ascii_upcase')"
case "$state" in
    RUNNING)
        echo "✓ VM $VM_NAME already running. Skipping creation."
        ;;
    "")
        echo "✓ Creating VM $VM_NAME ($VM_CPU vCPU, $VM_MEMORY RAM, $VM_DISK disk on pool $VM_POOL)..."
        lxc init "$VM_IMAGE" "$VM_NAME" --vm \
            --storage "$VM_POOL" \
            --config "limits.cpu=$VM_CPU" \
            --config "limits.memory=$VM_MEMORY" \
            --device "root,size=$VM_DISK"
        # Pipe user-data to lxc to avoid snap confinement issues. Never leave a
        # VM that exists but was never provisioned: the next run would see it
        # and skip creation forever.
        if ! lxc config set "$VM_NAME" cloud-init.user-data - < "$RENDER_TMP"; then
            echo "Error: failed to set cloud-init user-data; removing the partial VM." >&2
            lxc delete -f "$VM_NAME" || true
            exit 1
        fi
        lxc start "$VM_NAME"
        vm_wait_ready "$VM_NAME"
        ;;
    *)
        echo "✓ VM $VM_NAME exists but is $state. Starting it..."
        lxc start "$VM_NAME"
        vm_wait_ready "$VM_NAME"
        ;;
esac

# Re-derive the address rather than trusting a possibly stale cached lease.
addr="$(vm_addr "$VM_NAME")"
printf '%s\n' "$addr" > "$VM_IP_FILE"
chmod 0600 "$VM_IP_FILE"

# Capture the host key out of band via the LXD agent, so ssh can verify it
# instead of blindly trusting whatever answers on a recycled bridge address.
hostkey="$(lxc exec "$VM_NAME" -- cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1-2)"
printf '%s\n' "$addr $hostkey" > "$VM_KNOWN_HOSTS"
chmod 0600 "$VM_KNOWN_HOSTS"

# LXD remote setup (server side): the workshop container connects as an lxc
# CLIENT. Tokens MUST be time-bounded: LXD 6.x has no --expires-after on
# `trust add`; expiry is server-side only, and the expression is
# case-sensitive - `1H` parses, `1h` is rejected as invalid.
lxc exec "$VM_NAME" -- lxd waitready --timeout=60
lxc exec "$VM_NAME" -- lxc config set core.https_address "${addr}:8443"
lxc exec "$VM_NAME" -- lxc config set core.remote_token_expiry 1H

# Sweep by NAME first: revoking only the recorded fingerprint cannot clean up
# a certificate left by an earlier run that died between minting and
# recording, and that orphan would otherwise be unrevocable.
vm_revoke_trust
# shellcheck disable=SC2016  # $fp expands on the VM, not here
lxc exec "$VM_NAME" -- sh -c '
    lxc config trust list --format json \
        | jq -r ".[] | select(.name==\"openstack-workshop\") | .fingerprint" \
        | while read -r fp; do [ -n "$fp" ] && lxc config trust remove "$fp"; done
    lxc config trust revoke-token openstack-workshop >/dev/null 2>&1 || true'

# Restricted to the default project: the client needs instance lifecycle on
# `default` and nothing more. The token is stored 0600 under .state/vm/ so the
# user can redeem it from the workshop container (see docs/dev-vm.rst);
# destroy.sh revokes the certificate server-side and removes this file.
token="$(lxc exec "$VM_NAME" -- lxc config trust add --quiet --name=openstack-workshop \
    --restricted --projects default)"
printf '%s\n' "$token" > "$VM_TOKEN_FILE"
chmod 0600 "$VM_TOKEN_FILE"

# Record: full 64-hex fingerprint (list truncates; JSON does not). Fail on
# more than one match rather than silently recording an arbitrary one.
mapfile -t fingerprints < <(lxc exec "$VM_NAME" -- lxc config trust list --format json \
    | jq -r '.[] | select(.name=="openstack-workshop") | .fingerprint')
if [ "${#fingerprints[@]}" -ne 1 ]; then
    echo "Error: expected exactly 1 'openstack-workshop' certificate on $VM_NAME, found ${#fingerprints[@]}." >&2
    printf '       %s\n' "${fingerprints[@]}" >&2
    echo "       Revoke the extras: lxc exec $VM_NAME -- lxc config trust remove <fingerprint>" >&2
    exit 1
fi
fingerprint="${fingerprints[0]}"
if ! [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
    vm_die "'$fingerprint' is not a 64-hex-char fingerprint."
fi
printf '%s\n' "$fingerprint" > "$VM_FP_FILE"
chmod 0600 "$VM_FP_FILE"

echo "✓ lxc remote material recorded (fingerprint: ${fingerprint:0:16}...)"
echo "✓ VM $VM_NAME ready at $addr (saved to $VM_IP_FILE)"
echo "  ssh:        just vm-shell   (dev@$addr, key $VM_KEY)"
echo "  lxc remote: see docs/dev-vm.rst - token in $VM_TOKEN_FILE (expires 1H unredeemed)"
