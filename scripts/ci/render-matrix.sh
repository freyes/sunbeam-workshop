#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# render-matrix.sh - the D-15 bounded render matrix: render the six
# enumerated workshop names against the real profiles/ tree with the example
# config (config/example/config.json) layered in, and validate each rendered
# yaml against the vendored schema via scripts/check-render.sh.
#
#   Usage: bash scripts/ci/render-matrix.sh
#
# Idempotent: targets (.workshop/<name>.yaml, gitignored) are re-rendered
# fresh on every run; the example config is layered in only for the run's
# duration and the pre-run config state is restored on exit. The vendored
# schema is the contract - nothing is fetched from the network beyond the uv
# project sync inside scripts/render.sh / scripts/check-render.sh.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd -P)"

# D-15 bounded matrix: exactly these six names, no more.
NAMES=(sunbeam charmed packaging packaging-foo sunbeam-x charmed-x)

# Layer the example config in as config/config.json so renders exercise the
# config merge path with the repo's example values. An existing
# config/config.json is left untouched; a config we installed is removed on
# exit, so the worktree is never dirtied.
EXAMPLE_CONFIG="$ROOT/config/example/config.json"
TARGET_CONFIG="$ROOT/config/config.json"
config_installed=0
cleanup() {
    if [ "$config_installed" -eq 1 ]; then
        rm -f -- "$TARGET_CONFIG"
    fi
}
trap cleanup EXIT

if [ ! -f "$EXAMPLE_CONFIG" ]; then
    echo "error: $EXAMPLE_CONFIG is missing" >&2
    exit 2
fi
if [ ! -e "$TARGET_CONFIG" ] && [ ! -L "$TARGET_CONFIG" ]; then
    cp -- "$EXAMPLE_CONFIG" "$TARGET_CONFIG"
    config_installed=1
fi

failed=0
for name in "${NAMES[@]}"; do
    if bash "$ROOT/scripts/render.sh" "$name" \
        && bash "$ROOT/scripts/check-render.sh" "$ROOT/.workshop/$name.yaml"; then
        echo "PASS $name"
    else
        echo "FAIL $name" >&2
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "render matrix: FAIL" >&2
    exit 1
fi
echo "render matrix: OK (${#NAMES[@]} renders validated)"
