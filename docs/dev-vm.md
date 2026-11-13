---
orphan: true
---

# Sidecar dev VM

The optional sunbeam sidecar VM (draft D-11): an LXD VM on the **host** that runs the
things the workshop container cannot - craft builds (destructive-mode on the 26.04
guest; nested LXD in the container is blocked upstream: `canonical/workshop#769`,
`canonical/lxd#14770`) and a MicroK8s 1.32-classic + Juju 3.6 substrate for
func/deployment testing. Sunbeam profile only.

| Command | Effect |
|---|---|
| `just vm-create` | Create the VM, provision it, record ssh + LXD-remote material under `.state/vm/`. Repairs a stopped VM instead of recreating it |
| `just vm-status` | Report the VM state (read-only; non-zero unless RUNNING and coherent) |
| `just vm-shell` | Interactive ssh shell on the VM as the `dev` user |
| `just vm-destroy` | Confirm, revoke the LXD trust **server-side**, delete the VM. Keeps `.state/vm/` (keypair retained so a recreate stays idempotent) unless `PURGE=1` |

`vm-create` and `vm-destroy` are guarded (`assert-host`): they run on the host only,
never inside the workshop container (`USER=workshop`) and never on GitHub Actions
runners (`GITHUB_ACTIONS=true`). `just vm-destroy` additionally asks you to type the
VM name; `YES=1` skips the prompt for scripts.

Hardware comes from `config/vm.json` (`sunbeam-dev`, 8 vCPU / 16 GiB / 100 GiB,
`ubuntu:26.04`). Changing `cpu`, `memory` or `disk` requires
`just vm-destroy && just vm-create`.

## Provisioning

`scripts/vm/cloud-init.yaml.j2` is rendered fresh from the merged vars doc on every
`vm-create` - snap channels come from `profiles/sunbeam/vars.json`
(`1.32-classic/stable` `microk8s`, `3.6/stable` `juju`), so bump them there. It installs
the classic craft toolchain (`snapcraft`, `rockcraft`, `charmcraft`), `microk8s`, `juju` and
LXD, creates the `dev` user (password-less sudo, your injected ssh key), and repoints
`/etc/resolv.conf` at the real upstream resolver so nested instances get working DNS.

Provisioning is only considered complete when `/var/lib/sunbeam-provisioned` exists;
`cloud-init status: done` alone means the modules ran, not that they succeeded.

## Connecting from the workshop container

The container is an `lxc` **client** only; the VM's LXD is the server. `vm-create`
records everything under `.state/vm/` (mode 0600): `id_ed25519(.pub)`, `known_hosts`,
`ip`, `lxd-token` (one-time, expires 1H unredeemed) and `lxd-trust-fingerprint`.

```bash
# 1. Copy the token and address into the container (values are examples):
#    on the host:  cat .state/vm/lxd-token .state/vm/ip
# 2. In the workshop container, register the remote and switch to it:
lxc remote add sunbeam-vm https://<vm-address>:8443 --token <token>
lxc remote switch sunbeam-vm
# 3. ssh, with the key and known_hosts from .state/vm/:
ssh -i .state/vm/id_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=.state/vm/known_hosts dev@<vm-address>
```

## Trust lifecycle

The container authenticates to the VM's LXD with a client certificate minted
server-side on the VM:

1. `core.remote_token_expiry` is `1H`, so an unredeemed token cannot become a
   permanent credential (the expression is case-sensitive: `1H` parses, `1h` does not).
2. Certificates are minted `--restricted --projects default`: instance lifecycle on
   `default` and nothing more.
3. The 64-hex fingerprint is recorded in `.state/vm/lxd-trust-fingerprint`;
   fingerprints resolve by prefix in LXD, so the full length is validated before use.
4. Revocation happens **on the VM** during `just vm-destroy`
   (`lxc exec <vm> -- lxc config trust remove <fingerprint>`), verified by reading the
   trust store back, failing closed (the record is kept if the store cannot be read).
   `lxc remote remove` is *not* revocation - it only drops client-side config.

## When the DHCP lease moves

The VM's address is cached in `.state/vm/ip`. If the lease changes, `just vm-status`
says so explicitly; re-running `just vm-create` re-points everything.
