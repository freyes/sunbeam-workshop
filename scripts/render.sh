#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# render.sh - render .workshop/<NAME>.yaml from a profile jinja2 template.
#
#   Usage: bash scripts/render.sh NAME     (NAME e.g. sunbeam, packaging-foo)
#
# Flow (draft decisions D-13, D-14):
#   1. resolve NAME -> (profile, suffix) via the sunbeam_workshop vars module;
#      its exit codes are the render contract and propagate unchanged:
#      3 unknown profile prefix (lists valid profiles), 4 invalid workshop
#      name, 5 .workshop/ directory collision
#   2. write the merged vars doc to a fresh temp file VARS_TMP
#   3. render profiles/<profile>/workshop.yaml.j2 with jinja2-cli (file form:
#      the first positional is a template PATH) to a temp output inside
#      .workshop/ - same filesystem, so the publish below is an atomic rename
#   4. post-validate with python3: yaml.safe_load parses, top-level name:
#      equals NAME, base: present - the target is never written on failure
#   5. atomically mv the temp output to .workshop/<NAME>.yaml
#
# Re-rendering the same NAME overwrites deterministically (idempotent).
#
# SUNBEAM_WORKSHOP_ROOT overrides the repo root (the test suite uses it to
# render fixture profiles from a mktemp ROOT). The vars module discovers the
# root from the current directory (sunbeam_workshop.vars.find_root), so it is
# invoked with the root as its cwd.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "${SUNBEAM_WORKSHOP_ROOT:-$SCRIPT_DIR/..}" >/dev/null 2>&1 && pwd -P)"

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: bash scripts/render.sh NAME" >&2
    echo "  NAME  workshop instance name: a profile (sunbeam, charmed, packaging)" >&2
    echo "        or a suffixed instance of one (e.g. packaging-foo)." >&2
    [ "${1:-}" = "" ] && exit 2 || exit 0
fi
name="$1"

VARS_TMP=""
OUT_TMP=""
cleanup() {
    [ -z "$VARS_TMP" ] || rm -f -- "$VARS_TMP"
    [ -z "$OUT_TMP" ] || rm -f -- "$OUT_TMP"
}
trap cleanup EXIT

# 1+2. Resolve NAME and capture the merged vars doc in a fresh temp file.
VARS_TMP="$(mktemp --suffix=.json)"
status=0
( cd "$ROOT" && uv run --frozen --project "$SCRIPT_DIR" python -m sunbeam_workshop vars "$name" ) > "$VARS_TMP" || status=$?
if [ "$status" -ne 0 ]; then
    exit "$status"
fi

profile="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["profile"])' < "$VARS_TMP")"
shadow_warning="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["shadow_warning"])' < "$VARS_TMP")"

if [ "$shadow_warning" = "True" ]; then
    echo "warning: profiles/$name/ shadows the existing instance .workshop/$name/ - rendering the profile (D-13)." >&2
fi

template="$ROOT/profiles/$profile/workshop.yaml.j2"
if [ ! -f "$template" ]; then
    echo "error: $template is missing; profile templates land with the profiles work item." >&2
    exit 2
fi

# 3. Render to a temp file inside .workshop/ so the final mv is a rename on
# one filesystem (atomic). jinja2-cli roots its FileSystemLoader at the
# template's own directory, so includes stay inside the profile dir.
mkdir -p "$ROOT/.workshop"
target="$ROOT/.workshop/$name.yaml"
OUT_TMP="$(mktemp "$ROOT/.workshop/.render.XXXXXX")"
"$SCRIPT_DIR/jinja2" "$template" "$VARS_TMP" > "$OUT_TMP"

# 4. Post-validate: parse the render, require name: == NAME and a base: key.
if ! validation_error="$(python3 - "$OUT_TMP" "$name" 2>&1 <<'PY'
import sys

import yaml

path, expected = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
except yaml.YAMLError as exc:
    print(f"error: rendered {path} does not parse as YAML: {exc}", file=sys.stderr)
    sys.exit(1)
if not isinstance(doc, dict):
    print(f"error: rendered {path} is not a YAML mapping", file=sys.stderr)
    sys.exit(1)
rendered = doc.get("name")
if rendered != expected:
    print(f"error: rendered name {rendered!r} != requested name {expected!r}", file=sys.stderr)
    sys.exit(1)
if doc.get("base") is None:
    print("error: rendered workshop definition has no top-level 'base:'", file=sys.stderr)
    sys.exit(1)
PY
)"; then
    [ -z "$validation_error" ] || echo "$validation_error" >&2
    echo "error: post-validation failed; $target was not written." >&2
    exit 2
fi

# 5. Atomic publish; a re-render overwrites deterministically.
mv -f -- "$OUT_TMP" "$target"
OUT_TMP=""
echo "✓ Rendered .workshop/$name.yaml (profile: $profile)"
