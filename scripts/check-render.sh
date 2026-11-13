#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# check-render.sh - validate a rendered workshop yaml against the VENDORED
# workshop JSON schema (schema/workshop-json-schema.json).
#
#   Usage: bash scripts/check-render.sh FILE
#
# The vendored schema is the contract (D-15): this script never fetches a
# schema from the network - re-vendor with scripts/vendor-schema.sh instead.
# Unknown top-level fields are rejected (additionalProperties: false).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: bash scripts/check-render.sh FILE" >&2
    echo "  FILE  rendered workshop yaml (e.g. .workshop/packaging.yaml)." >&2
    [ "${1:-}" = "" ] && exit 2 || exit 0
fi
file="$1"

schema="$ROOT/schema/workshop-json-schema.json"
if [ ! -s "$schema" ]; then
    echo "error: $schema is missing or empty; re-vendor with bash scripts/vendor-schema.sh" >&2
    exit 2
fi
if [ ! -f "$file" ]; then
    echo "error: $file not found - render it first with bash scripts/render.sh NAME" >&2
    exit 2
fi

"$SCRIPT_DIR/check-jsonschema" --schemafile "$schema" "$file"
