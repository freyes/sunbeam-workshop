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
  `install_agentic_skills`, `pin_forge_host_keys`, `write_opencode_auth`,
  `check_opencode_auth`, git identity) live there
  and are never duplicated into a hook. Keep the
  `# shellcheck source=scripts/hooks/lib-common.sh` directive so the gate
  resolves it.
- Provisioning failures in `setup-project` are loud but non-fatal via the
  `run_step` wrapper: a swallowed failure once left a "ready" workshop
  without its tooling, so `check-health` is the authoritative gate.
- No secrets in hooks, ever. Identity comes from the persisted merged vars
  doc (`/project/.state/<name>.vars.json`, 0600, written by `setup.sh`);
  credentials come from the host keyring through the secret plug.
- Secret reads in hooks MUST wrap the `workshopctl get-secret` call - and
  any expansion of its result, including empty-key checks and the JSON
  build - in a brace group with stderr discarded, exactly as
  `write_opencode_auth` does: Workshop runs hooks under xtrace with
  `--verbose`, and bash traces assignment results and argv expansions, so
  the key would otherwise reach the trace log. Never pass a key through
  argv (e.g. `jq --arg`); pipe it via stdin instead.
- Never `uv tool install` - it ignores hashes. Venvs are built with
  `--require-hashes` from the vendored `tox-requirements.txt`
  (`build_tox_venv`), rebuilt only when the requirements file's sha256
  changes.
- Vendored payloads (`tox-requirements.in/.txt`) sit beside the hooks
  NON-executable and shebang-less so the shellcheck gate skips them.

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
- The opencode auth gate is corrupt-only: `check_opencode_auth` gates a
  present-but-malformed `auth.json` as `corrupt-opencode-auth`, but an
  ABSENT file never fails health - the secret plug cannot be connected
  until the workshop is Ready, so a hard absence gate would deadlock the
  very first launch.

## Verify

`just lint` (hook shellcheck via the gate) and `just test`; then
`just render <name>` + `bash scripts/check-render.sh .workshop/<name>.yaml`
if the SDK set changed.
