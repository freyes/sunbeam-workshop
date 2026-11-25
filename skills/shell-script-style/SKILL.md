---
name: shell-script-style
description: Use when writing or editing any shell in this repo - scripts/*.sh, just recipe bodies, or SDK hooks. Defines the script-file discipline (D-12), the shellcheck gates, and the nested-quoting trap.
---

# Shell Script Style

## When to Use

- Creating or editing any `*.sh` under `scripts/` (including `scripts/vm/`,
  `scripts/ci/`, `scripts/qa/host/`, `scripts/tests/`).
- Editing a recipe body in `Justfile` or `just/*.just`.
- Authoring SDK hooks under `.workshop/*-tools/hooks/` (pair with the
  `hook-authoring` skill for the lifecycle contract).

## Rules

- **Shell lives in script files, not inline** (D-12). Just recipes are thin
  dispatchers (`exec bash scripts/<name>.sh ...`); logic lives in the script.
  Python (uv-managed, `scripts/openstack_workshop/`) is preferred for
  repo/config tooling where a choice exists (IS-9).
- Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`,
  and carries the Canonical copyright header like its neighbors.
- Library files (e.g. `scripts/hooks/lib-common.sh`, `scripts/vm/lib-vm.sh`)
  are SOURCED, never executed: they set no shell options - the sourcing
  script owns `set -euo pipefail`.
- Everything must be shellcheck-clean. Run the gates before you commit:
  - `just lint` - the full local twin (shellcheck over `scripts/**/*.sh`,
    the hook/just gate, actionlint, config/template validation).
  - `bash scripts/check-just-shell.sh` - shellcheck over SDK hooks
    (live discovery) and, with arguments, over just recipe bodies
    (`bash scripts/check-just-shell.sh Justfile just/*.just`).
- **Never glob `.workshop/*/hooks/*` into shellcheck directly.** Non-shell
  payloads (`tox-requirements.in/.txt`) share the hooks dir. The gate lints a
  hooks entry iff it is a regular EXECUTABLE file whose first line is a shell
  shebang (sh, bash, dash, ksh) - keep payload files non-executable and
  shebang-less and they are skipped.
- **The nested-quoting trap is real, not cosmetic.** A backtick, apostrophe,
  or double quote inside a nested `bash -lc '...'` payload corrupts or
  truncates the remote command - the gate has caught shipped defects where a
  backtick in a COMMENT became live command substitution spliced into the
  script sent to the sidecar VM. Keep payloads single-quoted, avoid inner
  quotes entirely, and let the gate parse comments and strings alike.
- Idempotence: every setup/vm script can be re-run to repair (IS-10).
  Converge instead of re-doing (existence checks, atomic temp-file + rename
  publishes, `trap cleanup EXIT`).
- Never print secrets. Tokens move by stdin pipe only; error paths must not
  echo credential material.
- Host-mutating scripts refuse to run inside the workshop container
  (`USER=workshop`) unless `I_KNOW_WHAT_IM_DOING=1`, mirroring the Justfile
  `assert-host` guard (see `scripts/secret-setup.sh` for the pattern).

## Tests

- Shell suites live in `scripts/tests/*.sh` and are discovered live by
  `scripts/tests/run.sh` (`just test`); a new suite is picked up without
  editing the runner. Use fixture roots via `OPENSTACK_WORKSHOP_ROOT` overrides
  and `mktemp` dirs; never test against the real tree's state.
- Python unit tests sit beside the package (`scripts/tests/test_*.py`) and
  run via `cd scripts && uv run --frozen pytest -q` (the CI `python-tests`
  job; `just test` covers the shell suites only).

## Definition of Done

`just lint` and `just test` both exit 0, from a clean tree, with your change
included. Paste the terminal output - exit claims without output are not
evidence.
