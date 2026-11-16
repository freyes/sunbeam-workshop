#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# golden.sh - pin the golden render baseline for the six D-15 matrix names.
#
#   Usage: bash scripts/tests/golden.sh
#
# Unlike the fixture-based suites in this directory, this suite renders the
# REAL profiles/ tree (mirroring scripts/ci/render-matrix.sh): it layers
# config/example/config.json in as config/config.json for the run's duration
# (trap-restored on exit), renders each name via scripts/render.sh, and
# byte-compares the rendered .workshop/<name>.yaml against the pinned
# baseline scripts/tests/golden/<name>.yaml. A drifted render fails loudly
# naming the file; a missing golden file also fails loudly (never a
# vacuous pass). Regenerate baselines with scripts/ci/capture-golden.sh on a
# clean main tree.
set -euo pipefail

# Forward-compat: the user-vars layer discovery kill-switch lands in a later
# phase of the user-level-customization work; exporting it today is harmless
# and keeps this suite hermetic once dev machines can carry user layers.
export SUNBEAM_WORKSHOP_NO_USER_LAYERS=1

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT=$(cd -- "${TEST_DIR}/../.." >/dev/null 2>&1 && pwd -P)
GOLDEN_DIR="${TEST_DIR}/golden"

# D-15 bounded matrix: exactly these six names, no more.
NAMES=(sunbeam charmed packaging packaging-foo sunbeam-x charmed-x)

# Layer the example config in as config/config.json so renders exercise the
# config merge path with the repo's example values (render-matrix pattern).
# An existing config/config.json is left untouched; a config we installed is
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

failed=0
for name in "${NAMES[@]}"; do
    golden="${GOLDEN_DIR}/${name}.yaml"
    rendered="${ROOT}/.workshop/${name}.yaml"
    if [ ! -f "${golden}" ]; then
        echo "FAIL ${name}: golden baseline ${golden} is missing - regenerate with scripts/ci/capture-golden.sh" >&2
        failed=1
        continue
    fi
    if ! bash "${ROOT}/scripts/render.sh" "${name}"; then
        echo "FAIL ${name}: render failed" >&2
        failed=1
        continue
    fi
    if cmp -- "${golden}" "${rendered}"; then
        echo "PASS ${name}"
    else
        echo "FAIL ${name}: rendered ${rendered} drifted from golden ${golden}" >&2
        failed=1
    fi
done

if [ "${failed}" -ne 0 ]; then
    echo "golden render baseline: FAIL" >&2
    exit 1
fi
echo "golden render baseline: OK (${#NAMES[@]} renders byte-identical)"
