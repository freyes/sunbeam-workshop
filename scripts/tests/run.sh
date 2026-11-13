#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# run.sh - discover and run every shell test suite under scripts/tests/.
#
#   Usage: bash scripts/tests/run.sh
#
# Suites are discovered LIVE by glob (scripts/tests/*.sh) on every run; this
# file excludes itself. Suites run via `bash <suite>` and pass when they exit
# 0. Every suite runs even after a failure, so the summary reports a verdict
# per suite; the exit status is non-zero if any suite failed.
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
SELF=$(basename -- "${BASH_SOURCE[0]}")

suites=()
for suite in "$TEST_DIR"/*.sh; do
    [ -f "$suite" ] || continue
    [ "$(basename -- "$suite")" = "$SELF" ] && continue
    suites+=("$suite")
done

if [ "${#suites[@]}" -eq 0 ]; then
    echo "error: no test suites found in $TEST_DIR" >&2
    exit 2
fi

failed_suites=()
for suite in "${suites[@]}"; do
    name=$(basename -- "$suite")
    echo "== $name"
    status=0
    bash "$suite" || status=$?
    if [ "$status" -eq 0 ]; then
        echo "-- PASS $name"
    else
        failed_suites+=("$name")
        echo "-- FAIL $name (exit $status)"
    fi
done

echo
echo "== suite summary: $((${#suites[@]} - ${#failed_suites[@]})) passed, ${#failed_suites[@]} failed"
if [ "${#failed_suites[@]}" -ne 0 ]; then
    printf 'FAIL %s\n' "${failed_suites[@]}"
    exit 1
fi
