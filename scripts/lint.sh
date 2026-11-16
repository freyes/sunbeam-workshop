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
#      glob .workshop/*/hooks/* into shellcheck directly (todo 21) - plus
#      user hook fragments under config/local/hooks/ when present
#      (config/local/ is gitignored and usually absent, e.g. in CI)
#   3. just-gate: shellcheck of recipe bodies in Justfile + just/*.just
#   4. actionlint on .github/workflows/*.yaml (a version- and checksum-pinned
#      binary is downloaded to a temp dir when actionlint is not on PATH)
#   5. config-validate: json.tool over config/**/*.json, a bare jinja2
#      Environment parse (no include resolution) of profiles/**/*.j2, and -
#      via the uv PROJECT python (the PyYAML trap, render.sh L114-117: the
#      system python3 has no PyYAML on a fresh host) - yaml.safe_load over
#      config/**/*.yaml + profiles/*/vars.{json,yaml}, same-dir
#      <base>.json+<base>.yaml coexistence errors, and .yml rejection
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

# User hook fragments. config/local/ is gitignored user customization:
# present on dev machines that use the feature, absent in CI - the nullglob
# set above expands the glob to nothing there.
fragment_files=(config/local/hooks/**/*.sh)
if [ "${#fragment_files[@]}" -gt 0 ]; then
    echo "   shellcheck: ${#fragment_files[@]} user hook fragment(s) under config/local/hooks/"
    shellcheck "${fragment_files[@]}"
fi

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

# YAML data docs + the format-flexibility rules (decision 5, traps 6/12).
# This block MUST run under the uv project python: the system python3 has no
# PyYAML on a fresh host (render.sh L114-117 documents the trap).
uv run --frozen --project scripts python - <<'PYEOF'
import glob
import sys

import yaml

bad = 0


def fail(message):
    global bad
    print(f"config-validate: {message}", file=sys.stderr)
    bad += 1


# `.yml` is never consulted by the loader; reject it wherever a data doc
# could live, with a rename hint.
yml_files = sorted(
    glob.glob("config/**/*.yml", recursive=True)
    + glob.glob("profiles/**/*.yml", recursive=True)
)
for path in yml_files:
    fail(f"{path}: '.yml' files are never read; rename to {path[:-4] + '.yaml'}")

# One slot = <base>.json OR <base>.yaml, never both (loader.load_doc raises
# the same coexistence error at load time).
for tree in ("config", "profiles"):
    json_stems = {p[: -len(".json")] for p in glob.glob(f"{tree}/**/*.json", recursive=True)}
    yaml_stems = {p[: -len(".yaml")] for p in glob.glob(f"{tree}/**/*.yaml", recursive=True)}
    for stem in sorted(json_stems & yaml_stems):
        fail(f"{stem}.json and {stem}.yaml coexist; keep exactly one format per slot")

# Parse every YAML data doc. profiles/*/vars.json is included: JSON is a
# YAML subset, so yaml.safe_load validates both formats of the vars slot.
# config/local/ is gitignored and usually absent; the globs simply find
# nothing then.
data_docs = sorted(
    glob.glob("config/**/*.yaml", recursive=True)
    + glob.glob("profiles/*/vars.json")
    + glob.glob("profiles/*/vars.yaml")
)
for path in data_docs:
    try:
        with open(path, encoding="utf-8") as handle:
            yaml.safe_load(handle)
    except (yaml.YAMLError, UnicodeDecodeError) as exc:
        fail(f"{path}: does not parse: {exc}")

print(f"yaml data docs OK: {len(data_docs)} files parse")
if bad:
    sys.exit(1)
PYEOF

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
