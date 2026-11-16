(customize-with-hooks)=

# Customize provisioning with hook fragments

This guide customizes what runs while a workshop provisions - without
editing the repo's tracked hooks - using *user lifecycle fragments*: shell
files you drop under `config/local/hooks/`, sourced by the repo's
`setup-project` and `check-health` hooks at defined points. It also covers
the one thing fragments can never do, and the user-SDK pattern that covers
it instead.

## Where customization can hook in

```text
launch / refresh
  |
  |-- setup-base (root, PRE-MOUNT: /project is not mounted)
  |     -> fragments impossible here; use your own SDK (below)
  |
  |-- setup-project (workshop user, post-mount, cwd /project)
  |     |-- repo provisioning steps (lib-common helpers)
  |     |-- user fragments: setup-project.d/*.sh   <- fail-soft, LAST step
  |
  |-- check-health (root)
  |     |-- repo probes (tools, snaps, identity, ...)
  |     |-- user fragments: check-health.d/*.sh    <- fail-hard, before set-health okay
  |     +-- set-health okay
  v
Ready (all SDKs report okay)
```

Fragments live in the gitignored `config/local/hooks/` tree, addressed by
scope and hook:

```text
config/local/hooks/all/setup-project.d/*.sh
config/local/hooks/all/check-health.d/*.sh
config/local/hooks/<profile>/setup-project.d/*.sh
config/local/hooks/<profile>/check-health.d/*.sh
config/local/hooks/<instance>/setup-project.d/*.sh
config/local/hooks/<instance>/check-health.d/*.sh
```

Scope composition is `all`, then `<profile>` (for example `sunbeam`), then
`<instance>` (the workshop name, for example `sunbeam-x`). Within one
directory, fragments are sourced in lexical order - prefix names with
numbers (`10-...`, `20-...`) to control ordering. Only `*.sh` files are
picked up; missing or empty directories are a silent no-op.

## The setup-project contract (fail-soft)

`setup-project` runs as the workshop user after the project directory is
mounted, and sources its fragments as the **last** step, through the
`run_step` wrapper: a failing fragment prints a loud `ERROR` and the hook
continues. Fragments customize; they must not break provisioning - the
authoritative gate is `check-health`.

Each fragment is *sourced* (not executed) inside its own subshell, so:

- the shared helpers from `/project/scripts/hooks/lib-common.sh` are
  available (`run_step`, `run_once`, `find_vars_doc`,
  `apply_git_identity`, the provisioning helpers);
- a fragment's own `set -e` or `exit` cannot kill the hook - the subshell
  is the containment;
- executable bits and shebangs do not matter.

Hooks re-run on `workshop refresh`, so every fragment must be
**idempotent**. For one-shot work, gate it with `run_once <marker>`:

```bash
# config/local/hooks/all/setup-project.d/10-first-run-note.sh
# One-shot: runs only on the first provisioning of this workshop.
if run_once first-run-note; then
    echo "first provisioning of $(hostname)" >> "$HOME/.workshop-notes"
fi
```

`run_once` records markers under
`${XDG_STATE_HOME:-$HOME/.local/state}/sunbeam-workshop/run-once/`; later
runs of the same marker skip the body. Plain always-run steps are fine
when they converge (append-only files, `mkdir -p`, idempotent installs).

## The check-health contract (fail-hard, as root)

`check-health` runs as **root**, after all `setup-project` hooks, and
gates Ready. Its fragments run immediately before the final
`workshopctl set-health okay`: a failing fragment makes the hook report

```text
workshopctl set-health --code=user-fragment-<name> error
```

(`<name>` is the first failed fragment's basename without `.sh`), exit
nonzero, and the workshop never reaches Ready. A check-health fragment is
a health probe: exit 0 when your customization is in place, nonzero when
it is not.

Root context changes the rules:

- never call the `$HOME`-based lib-common helpers (they provision the
  *workshop user's* environment) - `check-health` sources lib-common
  definitions-only;
- to act on the workshop user's environment, use `as_workshop_user`:

```bash
# config/local/hooks/all/check-health.d/20-tox-on-path.sh
# Probe per-user tooling through the workshop user's login shell.
as_workshop_user bash -lc 'command -v tox' >/dev/null
```

When this fragment fails, `workshop info <name>` reports
`user-fragment-20-tox-on-path` as the health code.

## What fragments can never do: pre-mount work

`setup-base` runs *before* the project directory is mounted - from its
point of view `/project` does not exist, so `config/local/` is physically
invisible to it. There are no `setup-base` fragments, and none for the
save/restore-state pair either. The documented answer for pre-mount
customization (system packages, snap pins, base services) is the
**user-SDK pattern**: your own in-project SDK, whose `setup-base` ships
inside it.

Constraints (the Workshop snap enforces or requires each one):

- the directory lives at `.workshop/<my-sdk>-user-tools/`, is gitignored,
  and is never committed;
- `sdk.yaml`'s `name:` must equal the directory name;
- hooks are **real files, not symlinks** - the snap copies symlinks
  verbatim and they dangle inside the workshop;
- the directory is owned by the user who runs the launch;
- the whole directory is content-addressed at launch and refresh: any edit
  produces a new revision and the hooks re-run.

Wire the SDK into the chain with an `sdks.add` entry named
`project-<my-sdk>-user-tools`; see {doc}`add-a-sdk-locally` for the
walkthrough. The hook contract itself (five hooks, who runs as whom,
`set-health` semantics) is the same contract the repo's own SDKs follow.

```{warning}
Never put tokens or credentials in a fragment. Fragments are sourced into
hook logs, and `config/local/` is gitignored, not access-controlled.
Credentials come from the host keyring through the secret plug only
(see {doc}`authenticate-github`) - Invariant 1 applies to user code
exactly as to the tracked repo.
```

## Debugging

- `just layers <name>` lists every discovered fragment under "Hook
  fragments", in run order (paths only; content is never read) - the first
  stop when a fragment seems ignored.
- `workshop info <name>` shows the health state; a fragment failure
  surfaces there as `user-fragment-<name>`.
- The edit rule: fragments are sourced at hook run time, and hooks re-run
  on launch and refresh - after editing any layer or fragment, re-run
  `just setup <name>` (idempotent) to re-render, re-persist, and re-gate.

## Troubleshooting

**My fragment did not run.**
Check the path layout against `just layers <name>`: scope directory
(`all`, the profile, or the exact instance name), hook directory
(`setup-project.d` or `check-health.d`), `.sh` suffix. Non-`.sh` files
are ignored.

**A `setup-project` fragment failed but the workshop reached Ready.**
Fail-soft is the contract: the fragment's `ERROR` went to the hook log and
provisioning continued. If the state it creates is required, add a
`check-health.d` probe for it - that gate is fail-hard.

**A `check-health` fragment fails with permission errors on user files.**
It is running as root. Re-express the probe through `as_workshop_user`
instead of touching `$HOME` or the workshop user's files directly.
