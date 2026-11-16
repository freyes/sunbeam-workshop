#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# user-layers-fixture.sh - CI proof of the config/local/vars/ contract with
# SYNTHETIC user layers (CI runners have no real ones, and config/local/ is
# gitignored):
#
#   1. install a synthetic profile layer under config/local/vars/
#   2. render the bounded name `packaging` and validate it against the
#      vendored schema - user layers must never break the render path
#   3. assert the merged vars doc carries the customization: the sdks.add
#      entry lands between the profile extra_sdks and the project SDK, the
#      action merges, and the _layers provenance records the synthetic layer
#
#   Usage: bash scripts/ci/user-layers-fixture.sh
#
# The fixture exists only for the run's duration; a trap removes it on exit
# so the worktree is never dirtied. An existing config/local/ is real user
# customization and is never clobbered.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd -P)"

LOCAL_DIR="$ROOT/config/local"
created_local=0
cleanup() {
    if [ "$created_local" -eq 1 ]; then
        rm -rf -- "$LOCAL_DIR"
    fi
}
trap cleanup EXIT

if [ -e "$LOCAL_DIR" ]; then
    echo "error: $LOCAL_DIR already exists; refusing to clobber real user customization" >&2
    exit 2
fi
created_local=1
mkdir -p "$LOCAL_DIR/vars/profile"
cat > "$LOCAL_DIR/vars/profile/packaging.yaml" <<'EOF'
sdks:
  add:
    - name: ci-fixture-sdk
      channel: latest/stable
actions:
  ci-fixture-action: |
    echo fixture
EOF

bash "$ROOT/scripts/render.sh" packaging
bash "$ROOT/scripts/check-render.sh" "$ROOT/.workshop/packaging.yaml"

# The assertions run under the uv project python: the system python3 has no
# PyYAML on a fresh host (the render.sh L114-117 trap).
uv run --frozen --project "$ROOT/scripts" python - "$ROOT" <<'PY'
import json
import subprocess
import sys

root = sys.argv[1]

doc = json.loads(
    subprocess.run(
        ["uv", "run", "--frozen", "--project", f"{root}/scripts",
         "python", "-m", "sunbeam_workshop", "vars", "packaging"],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout
)

names = [entry["name"] for entry in doc["sdks"]]
errors = []
if "ci-fixture-sdk" not in names:
    errors.append(f"sdks chain {names} lacks the user-added ci-fixture-sdk")
elif names.index("ci-fixture-sdk") > names.index("project-packaging-tools"):
    errors.append(f"ci-fixture-sdk must land before the project SDK: {names}")
if doc["actions"].get("ci-fixture-action") != "echo fixture\n":
    errors.append(f"actions lost the user action: {doc['actions']!r}")
layer_paths = [entry["path"] for entry in doc["_layers"]]
if not any(path.endswith("config/local/vars/profile/packaging.yaml") for path in layer_paths):
    errors.append(f"_layers provenance lost the synthetic layer: {layer_paths}")

report = subprocess.run(
    ["uv", "run", "--frozen", "--project", f"{root}/scripts",
     "python", "-m", "sunbeam_workshop", "layers", "packaging"],
    cwd=root, check=True, capture_output=True, text=True,
).stdout
if "ci-fixture-sdk" not in report or "ci-fixture-action" not in report:
    errors.append("the layers report does not name the synthetic customization")

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    sys.exit(1)
print("user-layers fixture: vars doc + layers report carry the synthetic layer")
PY

echo "user-layers fixture: OK"
