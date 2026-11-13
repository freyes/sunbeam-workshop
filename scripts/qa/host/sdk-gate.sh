#!/usr/bin/env bash
# sdk-gate.sh - wave-1 SDK verification gate (plan todo 1; closes GAP-7 residual).
#
# Runs EXACTLY the plan's gate on a workshop-capable host (workshop snap +
# LXD >= 6.8): launch a scratch ubuntu@26.04 workshop named "gate" declaring
# the gh-cli, uv (channel latest/stable) and opencode SDKs, then assert that
# gh, uv and opencode answer `--version` inside the container. On any miss,
# apply the ck8s-dev fallbacks documented in the plan row and record the
# adjustment for Wave 2:
#   - gh: GitHub apt repo + keyring per ck8s-dev
#     .workshop/ck8s-dev-tools/hooks/setup-project.base lines 24-46
#   - uv: astral-uv snap (latest/stable --classic)
#   - opencode: no documented fallback -> recorded as UNRESOLVED for Wave 2
#
# State discipline: the .workshop/gate.yaml definition is written FRESH into
# a new mktemp scratch dir on every run; nothing is reused between runs.
#
# TIMING: a real gate run is SLOW. `workshop launch gate` downloads the
# ubuntu@26.04 base image and three SDKs on a cold host (expect 5-20 minutes;
# less when the LXD image is already cached). The script deliberately uses NO
# `--no-wait` flags: launch blocks until the change finishes, then the
# asserts run sequentially with clear progress echoes.
#
# NO real GitHub token is required. The gh-cli `github-token` secret-plug
# contract check is OPTIONAL and OFF by default; enable it only on a host
# where `gh auth status` already shows a (keyring) login:
#   GATE_CHECK_SECRET_PLUG=1 bash scripts/qa/host/sdk-gate.sh
#
# Other toggles (environment variables, no positional arguments):
#   GATE_EVIDENCE=<path>   evidence output file (default: ./sdk-gate-evidence.txt);
#                          append or paste its content into the repo's
#                          .omo/evidence/task-1-openstack-workshop.txt
#   GATE_KEEP=1            keep the scratch dir + gate workshop even on success
#                          (on failure they are always kept for debugging)
#
# Expected output on a workshop-capable host (abridged; versions drift):
#   ==> [1/6] checking host prerequisites (workshop snap, LXD >= 6.8)
#   ==> [2/6] writing fresh .workshop/gate.yaml into /tmp/sdk-gate.XXXXXXXXXX
#   ==> [3/6] workshop launch gate   (slow: base image + SDK downloads)
#   ==> [4/6] workshop info gate -> waiting for status: Ready
#   name: gate
#   base: ubuntu@26.04
#   status: Ready
#   sdks:
#     - name: gh-cli
#       channel: latest/stable
#     - name: uv
#       channel: latest/stable
#     - name: opencode
#       channel: latest/stable
#   ==> [5/6] assert: workshop exec gate -- gh --version
#   gh version 2.83.0 (2026-01-15)
#   https://github.com/cli/cli/releases/tag/v2.83.0
#   ==> [6/6] assert: workshop exec gate -- uv --version
#   uv 0.9.x (xxxxxxxx xxxx-xx-xx)
#   ==> assert: workshop exec gate -- opencode --version
#   1.x.x
#   PASS: evidence written to ./sdk-gate-evidence.txt
#
# In an LXD-less environment (e.g. a container where `which workshop` exits
# 1) the script aborts at step [1/6] with exit code 2 and creates nothing.

set -euo pipefail

EVIDENCE_OUT="${GATE_EVIDENCE:-$(pwd)/sdk-gate-evidence.txt}"
CHECK_SECRET_PLUG="${GATE_CHECK_SECRET_PLUG:-0}"
KEEP="${GATE_KEEP:-0}"
SCRATCH_DIR=""
GATE_INFO=""
SUCCESS=0
ADJUSTMENTS=()

step() {
  printf '==> %s\n' "$*"
}

record() {
  printf '%s\n' "$*" >>"$EVIDENCE_OUT"
}

cleanup() {
  if [ "$SUCCESS" -eq 1 ] && [ "$KEEP" != "1" ]; then
    if [ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ]; then
      (cd "$SCRATCH_DIR" && workshop remove gate) >/dev/null 2>&1 || true
      rm -rf -- "$SCRATCH_DIR"
    fi
  elif [ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ]; then
    echo "gate scratch dir kept for debugging: $SCRATCH_DIR" >&2
    echo "  remove with: (cd '$SCRATCH_DIR' && workshop remove gate) && rm -rf '$SCRATCH_DIR'" >&2
  fi
}
trap cleanup EXIT

# --- [1/6] host prerequisites ------------------------------------------------

require_host() {
  step "[1/6] checking host prerequisites (workshop snap, LXD >= 6.8)"
  if ! command -v workshop >/dev/null 2>&1; then
    echo "ERROR: 'workshop' not found; this host is not workshop-capable." >&2
    echo "       Install the workshop snap and LXD >= 6.8, then re-run." >&2
    exit 2
  fi
  if ! command -v lxc >/dev/null 2>&1; then
    echo "ERROR: 'lxc' not found; LXD >= 6.8 is required." >&2
    exit 2
  fi
  local version major minor rest
  version="$(lxc version 2>/dev/null | awk -F': *' '/^Server version:/{print $2}')"
  if [ -z "$version" ]; then
    echo "ERROR: cannot reach the LXD server ('lxc version' has no Server version)." >&2
    exit 2
  fi
  major="${version%%.*}"
  rest="${version#*.}"
  minor="${rest%%.*}"
  major="${major//[^0-9]/}"
  minor="${minor//[^0-9]/}"
  major="${major:-0}"
  minor="${minor:-0}"
  if [ "$major" -lt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -lt 8 ]; }; then
    echo "ERROR: LXD server version $version is too old; need >= 6.8." >&2
    exit 2
  fi
  echo "    workshop: $(command -v workshop)"
  echo "    LXD server version: $version (>= 6.8 OK)"
}

# --- [2/6] fresh scratch definition ------------------------------------------

write_gate_yaml() {
  step "[2/6] writing fresh .workshop/gate.yaml into $SCRATCH_DIR"
  mkdir -p "$SCRATCH_DIR/.workshop"
  if [ "$CHECK_SECRET_PLUG" = "1" ]; then
    # Augmented definition: adds the `system` secret slot the gh-cli SDK's
    # github-token plug connects to (canonical/gh-cli-sdk README contract).
    cat >"$SCRATCH_DIR/.workshop/gate.yaml" <<'EOF'
name: gate
base: ubuntu@26.04
sdks:
  - name: system
    slots:
      github-token:
        interface: secret
        attributes:
          service: "gh:github.com"
          username: ""
  - name: gh-cli
  - name: uv
    channel: latest/stable
  - name: opencode
EOF
  else
    cat >"$SCRATCH_DIR/.workshop/gate.yaml" <<'EOF'
name: gate
base: ubuntu@26.04
sdks:
  - name: gh-cli
  - name: uv
    channel: latest/stable
  - name: opencode
EOF
  fi
  record "gate.yaml (fresh, $SCRATCH_DIR/.workshop/gate.yaml):"
  record '```'
  while IFS= read -r line; do record "$line"; done <"$SCRATCH_DIR/.workshop/gate.yaml"
  record '```'
}

# --- [4/6] readiness -----------------------------------------------------------

wait_ready() {
  step "[4/6] workshop info gate -> waiting for status: Ready"
  local i info_out
  for i in $(seq 1 12); do
    info_out="$(workshop info gate 2>&1)" || true
    if printf '%s\n' "$info_out" | grep -qiE '^[[:space:]]*status:[[:space:]]*"?ready"?[[:space:]]*$'; then
      GATE_INFO="$info_out"
      printf '%s\n' "$GATE_INFO"
      return 0
    fi
    echo "    ... not Ready yet (attempt $i/12), sleeping 10s"
    sleep 10
  done
  echo "ERROR: workshop 'gate' did not reach status Ready; last 'workshop info gate' output:" >&2
  printf '%s\n' "$info_out" >&2
  return 1
}

# --- asserts + fallbacks -------------------------------------------------------

gate_exec() { # <label> <cmd...>; returns 0 on PASS, 1 on MISS (records both)
  local label="$1"
  shift
  step "assert: workshop exec gate -- $*"
  local out rc
  if out="$(workshop exec gate -- "$@" 2>&1)"; then
    printf '%s\n' "$out"
    record "PASS[$label]: \`workshop exec gate -- $*\`"
    record '```'
    record "$out"
    record '```'
    return 0
  else
    rc=$?
    printf '%s\n' "$out" >&2
    record "MISS[$label]: \`workshop exec gate -- $*\` (exit $rc)"
    record '```'
    record "$out"
    record '```'
    return 1
  fi
}

fallback_gh() { # ck8s-dev setup-project.base lines 24-46 (apt repo + keyring)
  step "fallback[gh]: installing gh via GitHub apt repo (ck8s-dev precedent)"
  local out rc
  # shellcheck disable=SC2016 # single quotes are intentional: this runs INSIDE the container
  if out="$(workshop exec gate -- bash -c '
    set -euo pipefail
    tmp_key="$(mktemp)"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$tmp_key"
    sudo mkdir -p -m 755 /etc/apt/keyrings
    sudo install -m 0644 "$tmp_key" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    rm -f "$tmp_key"
    deb_arch="$(dpkg --print-architecture)"
    cat <<EOF | sudo tee /etc/apt/sources.list.d/github-cli.sources
Enabled: yes
Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: ${deb_arch}
Signed-By: /etc/apt/keyrings/githubcli-archive-keyring.gpg
EOF
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends gh
  ' 2>&1)"; then
    printf '%s\n' "$out"
    record "FALLBACK[gh] applied: GitHub apt repo + keyring (setup-project.base lines 24-46)"
    ADJUSTMENTS+=("gh: gh-cli SDK missed on ubuntu@26.04; Wave 2 must install gh via the GitHub apt repo + vendored keyring (ck8s-dev setup-project.base lines 24-46) from a tools hook instead of the gh-cli SDK.")
    return 0
  else
    rc=$?
    printf '%s\n' "$out" >&2
    record "FALLBACK[gh] FAILED (exit $rc):"
    record '```'
    record "$out"
    record '```'
    return 1
  fi
}

fallback_uv() { # astral-uv snap per plan row
  step "fallback[uv]: installing uv via astral-uv snap (latest/stable --classic)"
  local out rc
  if out="$(workshop exec gate -- sudo snap install astral-uv --channel latest/stable --classic 2>&1)"; then
    printf '%s\n' "$out"
    record "FALLBACK[uv] applied: astral-uv snap latest/stable --classic"
    ADJUSTMENTS+=("uv: uv SDK missed on ubuntu@26.04; Wave 2 must install uv via the astral-uv snap (latest/stable --classic) from a tools hook instead of the uv SDK.")
    return 0
  else
    rc=$?
    printf '%s\n' "$out" >&2
    record "FALLBACK[uv] FAILED (exit $rc):"
    record '```'
    record "$out"
    record '```'
    return 1
  fi
}

check_secret_plug() {
  step "optional: gh-cli github-token secret-plug contract check (GATE_CHECK_SECRET_PLUG=1)"
  local out rc
  step "run: workshop connect gate/gh-cli:github-token gate/system:github-token"
  if out="$(workshop connect gate/gh-cli:github-token gate/system:github-token 2>&1)"; then
    printf '%s\n' "$out"
    record "SECRET-PLUG connect OK:"
    record '```'
    record "$out"
    record '```'
  else
    rc=$?
    printf '%s\n' "$out" >&2
    record "SECRET-PLUG connect FAILED (exit $rc):"
    record '```'
    record "$out"
    record '```'
    ADJUSTMENTS+=("gh-cli secret-plug: 'workshop connect gate/gh-cli:github-token gate/system:github-token' failed; the github-token secret-plug contract diverges from the canonical/gh-cli-sdk README; Wave 2 must re-derive the slot/plug wiring.")
    return 0
  fi
  if gate_exec "secret-plug" gh auth status; then
    record "SECRET-PLUG contract CONFIRMED: gh authenticates via the github-token plug."
  else
    ADJUSTMENTS+=("gh-cli secret-plug: plug connected but 'gh auth status' fails; the GH_TOKEN wrapper contract diverges from the canonical/gh-cli-sdk README; Wave 2 must re-derive it.")
  fi
}

main() {
  require_host

  {
    record "# sdk-gate run $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    record "host: $(uname -a)"
    record "workshop: $(command -v workshop 2>/dev/null || echo MISSING)"
    record ""
  }

  SCRATCH_DIR="$(mktemp -d /tmp/sdk-gate.XXXXXXXXXX)"
  write_gate_yaml

  cd "$SCRATCH_DIR"

  step "[3/6] workshop launch gate   (slow: base image + SDK downloads; no --no-wait)"
  workshop launch gate

  wait_ready
  record "'workshop info gate' (resolved channels/platforms):"
  record '```'
  record "$GATE_INFO"
  record '```'

  step "[5/6] gh assertion"
  if ! gate_exec gh gh --version; then
    fallback_gh
    gate_exec gh-after-fallback gh --version
  fi

  step "[6/6] uv + opencode assertions"
  if ! gate_exec uv uv --version; then
    fallback_uv
    gate_exec uv-after-fallback /snap/bin/uv --version
  fi
  if ! gate_exec opencode opencode --version; then
    record "UNRESOLVED[opencode]: opencode SDK missed on ubuntu@26.04 and the plan documents no fallback; Wave 2 must reassess (GAP-7 said the opencode SDK precedent was confirmed, so treat this as a regression signal)."
    ADJUSTMENTS+=("opencode: SDK missed on ubuntu@26.04, no documented fallback; UNRESOLVED - Wave 2 must reassess.")
  fi

  if [ "$CHECK_SECRET_PLUG" = "1" ]; then
    check_secret_plug
  fi

  {
    record ""
    record "=== summary ==="
    if [ "${#ADJUSTMENTS[@]}" -eq 0 ]; then
      record "no fallbacks needed: gh-cli + uv@latest/stable + opencode all resolve on ubuntu@26.04"
    else
      local adj
      for adj in "${ADJUSTMENTS[@]}"; do
        record "ADJUSTMENT: $adj"
      done
    fi
  }

  echo
  step "gate finished; evidence written to $EVIDENCE_OUT"
  echo "    append/paste it into the repo's .omo/evidence/task-1-openstack-workshop.txt"
  if [ "${#ADJUSTMENTS[@]}" -eq 0 ]; then
    echo "PASS: all SDKs resolved on ubuntu@26.04 without fallbacks"
  else
    echo "PASS-WITH-ADJUSTMENTS: ${#ADJUSTMENTS[@]} fallback(s) recorded for Wave 2"
  fi
  SUCCESS=1
}

main "$@"
