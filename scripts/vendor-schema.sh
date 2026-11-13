#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# vendor-schema.sh - re-extract the workshop JSON schema embedded in the
# workshop-definition docs page into schema/workshop-json-schema.json.
#
#   Usage: bash scripts/vendor-schema.sh
#
# Source: https://ubuntu.com/workshop/docs/reference/definition-files/workshop-definition.md
# (served as text/markdown). The schema's own $id URL is not fetchable - it
# 404s (Metis F-13) - so the vendored copy in this repo is the contract and
# nothing fetches a schema at CI runtime (D-15).
#
# The extraction is deliberately strict: locate the
# '### Workshop definition schema' section, take the single fenced ```json
# block inside it, and require the result to parse as a JSON object carrying
# string $schema/$id keys and type: "object". ANY change to that page
# structure fails the run instead of writing a mangled schema.
#
# Idempotent: if the vendored file already matches the live page byte-for-byte
# the script reports "already current" and exits 0 without touching it.
#
# WORKSHOP_DEFINITION_URL overrides the source URL (test hook for fixture
# pages, e.g. file:///tmp/mangled-page.md).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"

URL="${WORKSHOP_DEFINITION_URL:-https://ubuntu.com/workshop/docs/reference/definition-files/workshop-definition.md}"
TARGET="$ROOT/schema/workshop-json-schema.json"

PAGE_TMP=""
OUT_TMP=""
cleanup() {
    [ -z "$PAGE_TMP" ] || rm -f -- "$PAGE_TMP"
    [ -z "$OUT_TMP" ] || rm -f -- "$OUT_TMP"
}
trap cleanup EXIT

PAGE_TMP="$(mktemp)"
if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "$PAGE_TMP" "$URL"; then
    echo "error: failed to fetch $URL" >&2
    exit 1
fi

OUT_TMP="$(mktemp)"
if ! extract_error="$(python3 - "$PAGE_TMP" "$OUT_TMP" 2>&1 <<'PY'
import json
import sys

page_path, out_path = sys.argv[1], sys.argv[2]

with open(page_path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()

HEADING = "### Workshop definition schema"
try:
    start = lines.index(HEADING)
except ValueError:
    sys.exit(f"error: heading {HEADING!r} not found in page")

# Scan the section (up to the next h2 heading) for its fenced json block.
fence_open = None
for i in range(start + 1, len(lines)):
    line = lines[i]
    if line.startswith("## "):
        break
    if line.strip() == "```json":
        if fence_open is not None:
            sys.exit("error: more than one ```json fence in the schema section")
        fence_open = i

if fence_open is None:
    sys.exit("error: no ```json fence found under the schema section heading")

block = []
for i in range(fence_open + 1, len(lines)):
    line = lines[i]
    if line.strip() == "```":
        break
    block.append(line)
else:
    sys.exit("error: unterminated ```json fence in the schema section")

if not block:
    sys.exit("error: empty ```json block in the schema section")

text = "\n".join(block) + "\n"
try:
    schema = json.loads(text)
except json.JSONDecodeError as exc:
    sys.exit(f"error: schema block does not parse as JSON: {exc}")

if not isinstance(schema, dict):
    sys.exit("error: schema block is not a JSON object")
for key in ("$schema", "$id"):
    if not isinstance(schema.get(key), str):
        sys.exit(f"error: schema is missing a string {key!r} key")
if schema.get("type") != "object":
    sys.exit("error: schema 'type' is not 'object'")

with open(out_path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
)"; then
    echo "error: failed to extract the workshop JSON schema from $URL" >&2
    [ -z "$extract_error" ] || echo "$extract_error" >&2
    echo "hint: the page structure may have changed; fix the extraction above and re-vendor (see schema/README.md)." >&2
    exit 1
fi

if [ -f "$TARGET" ] && cmp -s -- "$OUT_TMP" "$TARGET"; then
    echo "✓ schema/workshop-json-schema.json already current (matches $URL)"
    exit 0
fi
mv -f -- "$OUT_TMP" "$TARGET"
OUT_TMP=""
echo "✓ vendored schema/workshop-json-schema.json from $URL"
