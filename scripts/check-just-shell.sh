#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Lint every shell recipe body in the Justfile and just/*.just, plus the SDK
# hooks under .workshop/*-tools/hooks/.
# Ported from ck8s-dev/scripts/check-just-shell.sh; intentional divergences:
# the project name (the hook glob covers .workshop/*-tools instead of
# ck8s-dev-tools), an optional file-list argument, the container re-exec
# (openstack-workshop has multiple named workshops, so there is no unambiguous
# container to re-exec into and shellcheck is simply required on PATH -
# preinstalled on GitHub ubuntu runners, in the workshop containers, and one
# `sudo apt install -y shellcheck` away on a host), hook discovery restricted
# to shell files (below), and `shellcheck -x --source-path=<repo root>` on
# hooks so their `# shellcheck source=scripts/hooks/lib-common.sh` directive
# resolves.
#
# Hook restriction mechanism (the ONLY one - there is deliberately NO name
# allowlist): hooks are discovered LIVE from the tree on every run, and a
# .workshop/*-tools/hooks/ entry is linted iff it is a regular EXECUTABLE
# file whose first line is a shell shebang shellcheck can parse (sh, bash,
# dash, or ksh). Non-shell payload files sharing the hooks dir - the vendored
# tox-requirements.in/.txt for the container's tox venv - are neither
# executable nor shebang'd and are skipped; the bare glob used to feed them
# to shellcheck and fail the gate. The recipe-body gate is unchanged.
#
# `just` recipe bodies are invisible to shellcheck: they live inside a Justfile,
# indented, with {{...}} interpolations that are not shell. This extracts each
# body to a real script and runs shellcheck over it.
#
# This gate is not cosmetic. It has caught three shipped defects in nested
# remote payloads (`vm "bash -lc '...'"`), which are otherwise invisible:
#   - SC2006 on a backtick in a comment -> LIVE command substitution, executed
#     locally, its stdout spliced into the script sent to the dev VM
#   - SC1078/SC1079 on a double quote  -> the payload is truncated

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "Error: shellcheck is not on PATH." >&2
    echo "       Install it with: sudo apt install -y shellcheck" >&2
    exit 1
fi

# Optional file list (e.g. `check-just-shell.sh Justfile just/*.just`);
# defaults to the root Justfile and every recipe module.
if [ "$#" -gt 0 ]; then
    sources=("$@")
else
    sources=("$project_dir/Justfile" "$project_dir"/just/*.just)
fi
for src in "${sources[@]}"; do
    if [ ! -f "$src" ]; then
        echo "Error: '$src' does not exist or is not a regular file" >&2
        exit 1
    fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$work" "${sources[@]}" << 'PYEOF'
import os
import re
import sys

work = sys.argv[1]
sources = sys.argv[2:]

count = 0
for path in sources:
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        match = re.match(r"^([a-z0-9_-]+)(\s+[^:]*)?:(?!=)", lines[i])
        if match and i + 1 < len(lines) and lines[i + 1].strip().startswith("#!"):
            name, shebang = match.group(1), lines[i + 1].strip()
            i += 2
            body = []
            while i < len(lines) and (lines[i].startswith("    ") or lines[i].strip() == ""):
                body.append(lines[i][4:] if lines[i].startswith("    ") else "")
                i += 1
            if "python" in shebang:
                continue
            # {{...}} is just-interpolation, not shell; substitute a placeholder
            # so shellcheck parses the surrounding shell.
            text = re.sub(r"\{\{.*?\}\}", "JUSTVAR", "\n".join(body).rstrip())
            stem = os.path.basename(path).replace(".", "_")
            with open(os.path.join(work, f"{stem}__{name}.sh"), "w") as handle:
                handle.write(shebang + "\n" + text + "\n")
            count += 1
        else:
            i += 1
print(f"extracted {count} recipe bodies")
PYEOF

failed=0
for script in "$work"/*.sh; do
    if ! output="$(shellcheck -s bash -f gcc "$script" 2>&1)" || [ -n "$output" ]; then
        echo "== $(basename "$script" .sh)"
        echo "$output"
        failed=1
    fi
done

shell_shebang='^#![[:space:]]*/?([^[:space:]]*/)*(env[[:space:]]+)?(ba|da|k)?sh([[:space:]].*)?$'
for hook in "$project_dir"/.workshop/*-tools/hooks/*; do
    [ -f "$hook" ] || continue
    [ -x "$hook" ] || continue
    IFS= read -r first_line < "$hook" || continue
    [[ $first_line =~ $shell_shebang ]] || continue
    if ! output="$(shellcheck -x --source-path="$project_dir" -f gcc "$hook" 2>&1)" || [ -n "$output" ]; then
        echo "== $hook"
        echo "$output"
        failed=1
    fi
done

# The gap above, closed. shellcheck sees only the outer layer, so scan the
# inner payloads directly: inside `vm "bash -lc '...'"` the region is single
# quoted, and ANY apostrophe closes it early. The remote login shell then
# re-tokenises what is left and bash -lc receives a truncated script.
#
# This shipped as a live BLOCKER (an echo reading 'just k8s bootstrap' broke
# `just k8s install` on every invocation), which is why it is a hard gate and
# not a warning. Escaped double quotes are fine and are used throughout.
python3 - "${sources[@]}" << 'PYEOF' || failed=1
import os
import re
import sys

sources = sys.argv[1:]

# Opening of a nested remote payload: vm "bash -lc ' ... or run ssh ... '
opener = re.compile(r"""(?:vm|run\s+ssh[^"]*)\s+"[^"]*bash\s+-lc\s+'""")
bad = 0
for src in sources:
    with open(src) as fh:
        lines = fh.read().split("\n")
    inside = False
    for n, line in enumerate(lines, 1):
        if not inside:
            if opener.search(line):
                inside = True
            continue
        # The payload ends on a line closing it: '" possibly indented.
        if re.match(r"^\s*'\"\s*$", line):
            inside = False
            continue
        if "'" in line:
            print(f"{src}:{n}: apostrophe inside a single-quoted remote payload"
                  f" - it closes the payload early and truncates the remote script")
            print(f"    {line.strip()}")
            bad += 1

if bad:
    print(f"found {bad} fatal quoting defect(s) in nested remote payloads",
          file=sys.stderr)
    sys.exit(1)
PYEOF

if [ "$failed" -ne 0 ]; then
    echo "shellcheck found problems" >&2
    exit 1
fi
echo "OK: shellcheck clean over all recipe bodies and hooks"
