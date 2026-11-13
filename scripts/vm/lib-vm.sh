# Copyright 2026 Canonical Ltd. All rights reserved.
#
# lib-vm.sh - shared helpers for the sunbeam sidecar VM lifecycle scripts.
# Sourced by scripts/vm/*.sh (create.sh, destroy.sh, shell.sh, status.sh);
# not executed directly. Expects ROOT to be set by the sourcing script.
#
# State layout under $ROOT/.state/vm/ (all mode 0600, dir 0700):
#   id_ed25519(.pub)      ssh keypair injected into the dev user
#   ip                    cached VM address (route-derived, never a stale lease)
#   known_hosts           guest host key, captured out of band via the LXD agent
#   lxd-token             one-time LXD trust token for the workshop container
#   lxd-trust-fingerprint recorded 64-hex fingerprint, revoked server-side on destroy
#
# destroy.sh preserves .state/vm unless PURGE=1 (IS-7).

# shellcheck shell=bash
# shellcheck disable=SC2034  # library globals, consumed by the sourcing scripts

VM_STATE="$ROOT/.state/vm"
VM_KEY="$VM_STATE/id_ed25519"
VM_IP_FILE="$VM_STATE/ip"
VM_KNOWN_HOSTS="$VM_STATE/known_hosts"
VM_TOKEN_FILE="$VM_STATE/lxd-token"
VM_FP_FILE="$VM_STATE/lxd-trust-fingerprint"
# Provisioning completion marker, inside the guest (written by cloud-init).
VM_MARKER="/var/lib/sunbeam-provisioned"

vm_die() {
    echo "Error: $*" >&2
    exit 1
}

# Host guard (IS-7), mirroring the Justfile assert-host recipe so a direct
# `bash scripts/vm/*.sh` invocation cannot bypass it. The sidecar VM lives on
# the HOST's LXD: it must not run on GitHub Actions runners, and nested LXD
# inside the workshop container is blocked upstream (canonical/workshop#769,
# canonical/lxd#14770). Bypass with I_KNOW_WHAT_IM_DOING=1 (fixtures, tests).
vm_guard_host() {
    if [ "${I_KNOW_WHAT_IM_DOING:-0}" = "1" ]; then
        echo "WARNING: I_KNOW_WHAT_IM_DOING=1 - skipping host guard checks" >&2
        return 0
    fi
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        vm_die "this script manages a host LXD VM and must never run on a GitHub Actions runner."
    fi
    if [ "${USER:-}" = "workshop" ]; then
        vm_die "run from the host, not inside the Workshop container; the host's LXD is not reachable from here."
    fi
}

# Validate config/vm.json has every field the lifecycle reads. `jq -r` yields
# the string "null" for a missing key, which would sail straight into
# `lxc init ... null --vm`; require every field explicitly.
vm_load_config() {
    local cfg="$ROOT/config/vm.json"
    [ -f "$cfg" ] || vm_die "$cfg is missing (the sidecar VM preset ships with the repo)."
    jq empty "$cfg" 2>/dev/null || vm_die "invalid JSON in config/vm.json"
    jq -e '.name and .image and .cpu and .memory and .disk and .pool' "$cfg" >/dev/null \
        || vm_die "config/vm.json must define name, image, cpu, memory, disk and pool."
    VM_NAME="$(jq -r '.name' "$cfg")"
    VM_IMAGE="$(jq -r '.image' "$cfg")"
    VM_CPU="$(jq -r '.cpu' "$cfg")"
    VM_MEMORY="$(jq -r '.memory' "$cfg")"
    VM_DISK="$(jq -r '.disk' "$cfg")"
    VM_POOL="$(jq -r '.pool' "$cfg")"
}

# Wait for a VM's agent, cloud-init, and provisioning marker. Every lxc probe
# is wrapped in `timeout` and every loop is bounded, so a wedged guest cannot
# hang the caller: 60x(3s+probe) for the agent, 180x(5s+probe) for cloud-init.
vm_wait_ready() {
    local name="$1"
    local agent_up=0 ci_status="" _

    echo -n "Waiting for the $name agent"
    for _ in $(seq 1 60); do
        if timeout 30 lxc exec "$name" -- true >/dev/null 2>&1; then
            agent_up=1
            break
        fi
        printf "."
        sleep 3
    done
    echo ""
    if [ "$agent_up" -ne 1 ]; then
        vm_die "the LXD agent in $name never became usable."
    fi

    echo -n "Waiting for cloud-init to finish in $name"
    for _ in $(seq 1 180); do
        ci_status="$(timeout 30 lxc exec "$name" -- cloud-init status 2>/dev/null | awk '{print $2}' || true)"
        if [ "$ci_status" = "done" ]; then
            break
        elif [ "$ci_status" = "error" ]; then
            echo ""
            echo "Error: cloud-init failed inside $name:" >&2
            lxc exec "$name" -- cloud-init status --long >&2 || true
            exit 1
        fi
        printf "."
        sleep 5
    done
    echo ""
    if [ "$ci_status" != "done" ]; then
        vm_die "cloud-init did not finish within 15 minutes."
    fi

    # `status: done` only means the modules ran, not that they succeeded, so
    # require the marker the runcmd script writes as its final action.
    if ! timeout 30 lxc exec "$name" -- test -e "$VM_MARKER"; then
        echo "Error: cloud-init reported 'done' but $VM_MARKER is missing," >&2
        echo "       so provisioning did not run to completion. Logs:" >&2
        lxc exec "$name" -- tail -n 30 /var/log/cloud-init-output.log >&2 || true
        exit 1
    fi
    echo "✓ cloud-init finished and provisioning completed"
}

# Print the VM's primary IPv4 address. Route-derived, so it always picks the
# external NIC and never the VM's own nested lxdbr0 address.
vm_addr() {
    local addr
    addr="$(lxc exec "$1" -- ip -4 -j route get 2.2.2.2 | jq -r '.[] | .prefsrc')"
    if [ -z "$addr" ]; then
        vm_die "could not determine the IPv4 address of $1."
    fi
    printf '%s\n' "$addr"
}

# Revoke the recorded LXD trust certificate ON THE VM (server-side; a
# client-side `lxc remote remove` only drops local config while the server
# keeps trusting the certificate). Idempotent: succeeds when the certificate
# is confirmed absent (revoked, already gone, or the VM that held it no longer
# exists). Fails closed: if the trust store cannot be read, the record is KEPT
# so a later run can still revoke.
vm_revoke_trust() {
    [ -f "$VM_FP_FILE" ] || return 0
    local fingerprint listing
    fingerprint="$(tr -d '[:space:]' < "$VM_FP_FILE")"

    if ! [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Error: $VM_FP_FILE is not a 64-hex-char fingerprint." >&2
        echo "       Refusing to revoke by prefix. Inspect the store with:" >&2
        echo "         lxc exec $VM_NAME -- lxc config trust list" >&2
        return 1
    fi

    if ! lxc info "$VM_NAME" >/dev/null 2>&1; then
        # No VM means no LXD database, so the certificate cannot still be trusted.
        echo "✓ VM $VM_NAME does not exist; its trust store is gone with it."
        rm -f "$VM_FP_FILE"
        return 0
    fi

    lxc exec "$VM_NAME" -- lxc config trust remove "$fingerprint" >/dev/null 2>&1 || true

    # Verify by reading the store back. Capture it first: piping a failed
    # `lxc exec` into `jq -e` yields exit 4, which is indistinguishable from
    # "certificate absent" and would drop the record while the cert lives on.
    if ! listing="$(lxc exec "$VM_NAME" -- lxc config trust list --format json 2>&1)"; then
        echo "Error: could not read the trust store on $VM_NAME; keeping the record." >&2
        printf '       %s\n' "$listing" >&2
        return 1
    fi
    if ! printf '%s' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "Error: unexpected trust-store output from $VM_NAME; keeping the record." >&2
        return 1
    fi
    if printf '%s' "$listing" | jq -e --arg fp "$fingerprint" 'any(.[]; .fingerprint == $fp)' >/dev/null; then
        echo "Error: certificate $fingerprint is still trusted on $VM_NAME." >&2
        return 1
    fi
    echo "✓ Certificate $fingerprint is not trusted on $VM_NAME."
    rm -f "$VM_FP_FILE"
}
