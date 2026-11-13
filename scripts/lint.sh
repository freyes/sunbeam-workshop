#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Local twin of .github/workflows/lint.yaml (drafts D-12, D-15; plan todo 14):
# the same checks in the same order, so `just lint` fails locally exactly
# where the CI lint workflow would fail.
#
#   1. shellcheck over every shell script under scripts/
#   2. SDK hooks via scripts/check-just-shell.sh - the gate discovers hooks
#      live and skips non-shell payload files (tox-requirements.*); never
#      glob .workshop/*/hooks/* into shellcheck directly (todo 21)
#   3. just-gate: shellcheck of recipe bodies in Justfile + just/*.just
#   4. actionlint on .github/workflows/*.yaml (a version- and checksum-pinned
#      binary is downloaded to a temp dir when actionlint is not on PATH)
#   5. config-validate: json.tool over config/**/*.json and a bare jinja2
#      Environment parse (no include resolution) of profiles/**/*.j2
#
# Everything below is globbed live from the tree on every run - new scripts,
# hooks, recipes, workflows, JSON, or templates are picked up without edits
# here.

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

echo "== 1/5 shellcheck: scripts/**/*.sh"
shopt -s globstar nullglob
shellcheck -x scripts/**/*.sh scripts/vm/*.sh scripts/qa/host/*.sh scripts/tests/*.sh

echo "== 2/5 shellcheck: SDK hooks via check-just-shell.sh (live discovery)"
bash scripts/check-just-shell.sh

echo "== 3/5 just-gate: Justfile + just/*.just recipe bodies"
bash scripts/check-just-shell.sh Justfile just/*.just

echo "== 4/5 actionlint: .github/workflows/*.yaml"
if command -v actionlint >/dev/null 2>&1; then
    actionlint .github/workflows/*.yaml
else
    actionlint_version="1.7.12"
    actionlint_sha256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    curl -sSfL -o "$work/actionlint.tar.gz" \
        "https://github.com/rhysd/actionlint/releases/download/v${actionlint_version}/actionlint_${actionlint_version}_linux_amd64.tar.gz"
    # Verify from inside $work so the printed checksum line is path-stable.
    (cd "$work" && echo "$actionlint_sha256  actionlint.tar.gz" | sha256sum -c -)
    tar -xzf "$work/actionlint.tar.gz" -C "$work" actionlint
    "$work/actionlint" .github/workflows/*.yaml
fi

echo "== 5/5 config-validate: config/**/*.json + profiles/**/*.j2"
json_files=(config/**/*.json)
if [ "${#json_files[@]}" -eq 0 ]; then
    echo "Error: no config/**/*.json files found" >&2
    exit 1
fi
for f in "${json_files[@]}"; do
    python3 -m json.tool "$f" > /dev/null
done
echo "json OK: ${#json_files[@]} files parse"

python3 - <<'PYEOF'
import glob
import sys

try:
    import jinja2
except ImportError:
    print("Error: python3 jinja2 is required for the template parse", file=sys.stderr)
    print("       Install it with: python3 -m pip install jinja2", file=sys.stderr)
    sys.exit(1)

# A bare Environment().parse() checks syntax only: {% include %} and
# {% set %} are parsed, never resolved or executed.
env = jinja2.Environment()
paths = sorted(glob.glob("profiles/**/*.j2", recursive=True))
bad = 0
for path in paths:
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    try:
        env.parse(source)
    except jinja2.TemplateSyntaxError as exc:
        print(f"{path}:{exc.lineno}: {exc.message}", file=sys.stderr)
        bad += 1
print(f"jinja2 OK: parsed {len(paths)} templates, {bad} invalid")
if bad or not paths:
    sys.exit(1)
PYEOF

echo "lint: all checks passed"
