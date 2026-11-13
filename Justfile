# Copyright 2026 Canonical Ltd. All rights reserved.

# List all available commands
default:
    @just --list

# Dependency of the guarded recipes (IS-7): setup, secret-setup, vm-create,
# vm-destroy, repos and the keyring writes behind them. Bypass with
# I_KNOW_WHAT_IM_DOING=1.
#
# Guard: host-mutating recipes only run on a real Ubuntu host with working LXD
assert-host:
    #!/bin/bash -e
    if [ "${I_KNOW_WHAT_IM_DOING:-0}" = "1" ]; then
        echo "WARNING: I_KNOW_WHAT_IM_DOING=1 - skipping assert-host checks" >&2
        exit 0
    fi
    refuse() {
        echo "Error: assert-host: $1" >&2
        echo "       $2" >&2
        echo "       Override with I_KNOW_WHAT_IM_DOING=1 to bypass." >&2
        exit 1
    }
    if [ "${USER:-}" = "workshop" ]; then
        refuse "this command must be run from the host, not inside the Workshop." \
            "Host-mutating recipes would otherwise run with the container's passwordless sudo."
    fi
    os_id="$(awk -F= '/^ID=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
    if [ "$os_id" != "ubuntu" ]; then
        refuse "host-mutating recipes require an Ubuntu host (found ID='${os_id:-unknown}' in /etc/os-release)." \
            "Run from an Ubuntu 24.04+ host instead."
    fi
    if ! command -v lxc >/dev/null 2>&1; then
        refuse "'lxc' was not found on PATH; a working LXD is required." \
            "Install with: sudo snap install lxd --channel=6/stable && sudo lxd init --minimal"
    fi
    server_version="$(lxc version 2>/dev/null | awk '/^Server version:/ {print $3}')"
    if [ -z "$server_version" ]; then
        refuse "the LXD daemon is not answering to 'lxc version'." \
            "Initialise with: sudo lxd init --minimal"
    fi

import 'just/setup.just'
import 'just/doctor.just'
import 'just/repos.just'
import 'just/secrets.just'
import 'just/vm.just'
import 'just/ci.just'
import 'just/docs.just'
