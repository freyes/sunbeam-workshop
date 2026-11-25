#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# capture-golden.sh - regenerate the golden render baselines under
# scripts/tests/golden/ for the six D-15 matrix names.
#
#   Usage: bash scripts/ci/capture-golden.sh
#
# Renders each name against the real profiles/ tree with the example config
# layered in (the scripts/ci/render-matrix.sh pattern) and refreshes
# scripts/tests/golden/<name>.yaml from the rendered output. This tool lives
# under scripts/ci/, NOT scripts/tests/: run.sh auto-discovers
# scripts/tests/*.sh as suites, and a regen tool there would run as a suite
# and overwrite the baselines it is meant to pin (A8).
set -euo pipefail

# Forward-compat: the user-vars layer discovery kill-switch lands in a later
# phase of the user-level-customization work; exporting it today is harmless
# and keeps captures hermetic once dev machines can carry user layers.
export OPENSTACK_WORKSHOP_NO_USER_LAYERS=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd -P)"
GOLDEN_DIR="${ROOT}/scripts/tests/golden"

# D-15 bounded matrix: exactly these six names, no more.
NAMES=(sunbeam charmed packaging packaging-foo sunbeam-x charmed-x)

echo "WARNING: capture-golden.sh refreshes the pinned render baselines." >&2
echo "WARNING: run it ONLY on a clean main tree - capturing from a dirty or" >&2
echo "WARNING: in-progress tree bakes unreviewed drift into the baseline." >&2

# Layer the example config in as config/config.json (render-matrix pattern):
# an existing config/config.json is left untouched; a config we installed is
# removed on exit, so the worktree is never dirtied.
EXAMPLE_CONFIG="${ROOT}/config/example/config.json"
TARGET_CONFIG="${ROOT}/config/config.json"
config_installed=0
cleanup() {
    if [ "${config_installed}" -eq 1 ]; then
        rm -f -- "${TARGET_CONFIG}"
    fi
}
trap cleanup EXIT

if [ ! -f "${EXAMPLE_CONFIG}" ]; then
    echo "error: ${EXAMPLE_CONFIG} is missing" >&2
    exit 2
fi
if [ ! -e "${TARGET_CONFIG}" ] && [ ! -L "${TARGET_CONFIG}" ]; then
    cp -- "${EXAMPLE_CONFIG}" "${TARGET_CONFIG}"
    config_installed=1
fi

mkdir -p -- "${GOLDEN_DIR}"
for name in "${NAMES[@]}"; do
    if ! bash "${ROOT}/scripts/render.sh" "${name}"; then
        echo "error: render of ${name} failed; baselines NOT refreshed" >&2
        exit 1
    fi
    cp -- "${ROOT}/.workshop/${name}.yaml" "${GOLDEN_DIR}/${name}.yaml"
    echo "captured ${GOLDEN_DIR}/${name}.yaml"
done

echo "golden baselines refreshed (${#NAMES[@]} files); review the diff before committing."
