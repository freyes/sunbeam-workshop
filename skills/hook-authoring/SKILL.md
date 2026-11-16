---
name: hook-authoring
description: Use when creating or editing SDK hooks under .workshop/*-tools/hooks/. Defines the five-hook lifecycle contract, root-pre-mount vs user-post-mount constraints, and workshopctl set-health semantics.
---

# Hook Authoring

## When to Use

- Adding or editing any hook in `.workshop/<profile>-tools/hooks/`.
- Reviewing a profile's provisioning or health gating.
- Debugging a workshop that never reaches `Ready`.

## The five-hook contract (upstream Workshop SDK lifecycle)

| Hook | Runs as | When Workshop runs it | Hard constraint |
| --- | --- | --- | --- |
| `setup-base` | root | launch/refresh: after the base image unpacks and the workshop starts, BEFORE the project directory is mounted and plugs/slots connect | **Self-contained**: `/project` is NOT mounted - reference nothing from the repo |
| `setup-project` | the `workshop` user | launch/refresh/restore: after the project dir is mounted and plugs/slots auto-connect, before the workshop is set Ready | cwd is `/project` |
| `save-state` | root | refresh/restore: before the old workshop is destroyed | From the OLD SDK revision; `$SDK_STATE_DIR` is visible only to this pair |
| `restore-state` | root | refresh/restore: after ALL SDKs' `setup-project` hooks | From the NEW SDK revision |
| `check-health` | root | launch: after all `setup-project` hooks; refresh/restore: after all `restore-state` hooks | Sets SDK health via `workshopctl set-health` |

Hooks are executable bash files named exactly as above, living in
`.workshop/<profile>-tools/hooks/`. `errexit` and `pipefail` are set by
Workshop (`xtrace` too under `--verbose`). A nonzero exit signals error.
SDK ordering in the rendered workshop definition determines hook order:
`system`, then the listed SDKs in order, then `sketch` - so this repo's
`project-<profile>-tools` hooks run after the store SDKs they depend on
(and, for packaging, after orange-dev-tools).

This repo ships `setup-base`, `setup-project`, and `check-health`. It does
not currently ship `save-state`/`restore-state`; add the pair only when an
SDK has state that must survive `workshop refresh`.

## Repo conventions

- `setup-base` configures SYSTEM state only: apt baselines, pinned snaps
  (installed via an idempotent install-or-refresh helper - `snap install`
  hard-fails on an already-installed snap), system services. Snap pins
  mirror `profiles/<profile>/vars.json`; bump them there, not ad hoc.
- `setup-project` configures the USER environment and SOURCES
  `/project/scripts/hooks/lib-common.sh` - the shared steps
  (`install_uv_pythons`, `build_tox_venv`, `seed_atlassian_mcp`,
  `install_agentic_skills`, `pin_forge_host_keys`, git identity) live there
  and are never duplicated into a hook. Keep the
  `# shellcheck source=scripts/hooks/lib-common.sh` directive so the gate
  resolves it.
- Provisioning failures in `setup-project` are loud but non-fatal via the
  `run_step` wrapper: a swallowed failure once left a "ready" workshop
  without its tooling, so `check-health` is the authoritative gate.
  `run_step` is defined ONCE in `lib-common.sh` (relocated from the
  per-profile hooks, where it was defined identically three times) -
  source it, never re-define it.
- No secrets in hooks, ever. Identity comes from the persisted merged vars
  doc (`/project/.state/<name>.vars.json`, 0600, written by `setup.sh`);
  credentials come from the host keyring through the secret plug.
- Never `uv tool install` - it ignores hashes. Venvs are built with
  `--require-hashes` from the vendored `tox-requirements.txt`
  (`build_tox_venv`), rebuilt only when the requirements file's sha256
  changes.
- Vendored payloads (`tox-requirements.in/.txt`) sit beside the hooks
  NON-executable and shebang-less so the shellcheck gate skips them.

## User lifecycle fragments (config/local/hooks/)

`run_user_fragments <hook> <profile>` (lib-common) sources user fragments
from `${SUNBEAM_WORKSHOP_FRAGMENT_ROOT:-/project/config/local/hooks}` at
two seams - there is no seam for `setup-base` (pre-mount: `/project` is
physically not mounted) or save/restore-state:

| Seam | Runs as | Where wired | Failure semantics |
| --- | --- | --- | --- |
| `setup-project.d/*.sh` | the `workshop` user | LAST step of `setup-project`, via `run_step "user fragments"` | **Fail-soft**: loud `ERROR`, hook continues; check-health gates |
| `check-health.d/*.sh` | root | Immediately before the final `set-health okay` | **Fail-hard**: first failure becomes `workshopctl set-health --code=user-fragment-<name> error`, exit nonzero, Ready is blocked |

Fragment contract:

- Paths: `config/local/hooks/{all,<profile>,<instance>}/<hook>.d/*.sh`.
  Scope order is `all` -> `<profile>` -> `<instance>` (`$(hostname)`, the
  bare workshop name); lexical order within a dir; `*.sh` glob only;
  missing/empty dirs are a silent no-op.
- Each fragment is SOURCED inside its own `( )` subshell with every
  lib-common helper in scope - a fragment's `set -e` death or `exit`
  cannot kill the sourcing hook. Failed basenames collect in
  `USER_FRAGMENT_FAILURES`; the function returns 1 when any failed.
- Fragments MUST be idempotent: hooks re-run on launch, refresh, and
  restore. `run_once <marker>` gates one-shot work (markers under
  `${XDG_STATE_HOME:-$HOME/.local/state}/sunbeam-workshop/run-once/`).
- check-health fragments run as ROOT: never call the `$HOME`-based
  provisioning helpers (they act on the workshop user's environment);
  use `as_workshop_user <cmd...>` (`sudo -u` the uid-1000 user) for
  user-context probes, mirroring the repo's own
  `sudo -u "$workshop_user" bash -lc ...` checks.
- `config/local/` is gitignored user state - never commit fragments, and
  never put credentials in them (Invariant 1).

## User SDKs (.workshop/*-user-tools/)

Pre-mount customization needs its own SDK, not a fragment. The
`.workshop/<my-sdk>-user-tools/` pattern (gitignored, never committed) is
an in-project SDK like the repo's own, wired in via a user layer
`sdks.add` entry named `project-<my-sdk>-user-tools` (`project-<X>`
resolves to `.workshop/<X>/` purely by path). Hard constraints:

- `sdk.yaml`'s `name:` must equal the directory name;
- hooks are REAL files, never symlinks - the Workshop snap copies symlinks
  verbatim and they dangle inside the workshop;
- the directory is owned by the invoking user;
- the whole SDK dir is content-addressed at launch and refresh: any edit
  is a new revision, so its hooks re-run. Health AND-aggregates across
  SDKs, and SDK order in the rendered definition sets hook order.

## `set-health` semantics (check-health)

- Gate on EVERYTHING `setup-base` and `setup-project` provision: tools on
  PATH (probe per-user tools through `sudo -u <workshop-user> bash -lc` so
  profile.d drops apply), pinned snap channels, uv-managed interpreters,
  cloned/symlinked skills, git identity, gerrit username.
- Every failure path calls
  `workshopctl set-health --code=<reason> error "<what is missing and which step provides it>"`
  and exits nonzero. Codes are kebab-case and specific
  (`missing-uv-pythons`, `missing-git-identity`), so `workshop info`
  tells the operator exactly what to re-run.
- The hook ends with `workshopctl set-health okay` only when every probe
  passed. Health states are `okay` / `waiting` / `error`; the workshop only
  reaches `Ready` when every SDK reports okay - `scripts/setup.sh`'s
  `wait_ready` polls exactly that aggregate signal.

## Verify

`just lint` (hook shellcheck via the gate) and `just test`; then
`just render <name>` + `bash scripts/check-render.sh .workshop/<name>.yaml`
if the SDK set changed.
