#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# lib-common.sh - shared bash functions sourced by every profile's
# setup-project hook (runs as the workshop user, post-mount). This is a
# library: source it, do not execute it. It sets no shell options - the
# sourcing hook owns `set -euo pipefail`. Every function is idempotent:
# re-running a hook converges to the same state without duplicating work.

# Put the uv SDK on PATH for non-login hook shells (the SDK drops
# /etc/profile.d/uv.sh, which hook shells do not read) and fail when uv
# cannot be found.
_lib_common_require_uv() {
    if ! command -v uv >/dev/null 2>&1 && [ -r /etc/profile.d/uv.sh ]; then
        # shellcheck disable=SC1091
        . /etc/profile.d/uv.sh
    fi
    command -v uv >/dev/null 2>&1
}

# install_uv_pythons <versions...> - install CPython versions via the uv SDK
# (e.g. `install_uv_pythons 3.10 3.12`). uv skips versions already present.
install_uv_pythons() {
    [ "$#" -ge 1 ] || { echo "ERROR: install_uv_pythons needs at least one version" >&2; return 2; }
    _lib_common_require_uv || { echo "ERROR: uv not found; is the uv SDK installed?" >&2; return 1; }
    uv python install "$@"
}

# build_tox_venv <requirements.txt> <venv-dir> - build the tox venv from a
# hash-locked requirements file and symlink tox into ~/.local/bin.
# Never `uv tool install`: it ignores hashes in constraint files.
# --system-certs trusts the OS CA store like pip and apt do, so
# TLS-intercepting corporate proxies keep working. A checksum marker makes
# re-runs cheap: the venv is rebuilt only when the requirements file changes.
build_tox_venv() {
    local req="${1:?build_tox_venv needs a requirements.txt path}"
    local venv="${2:?build_tox_venv needs a venv dir}"
    local uv_bin marker sum
    _lib_common_require_uv || { echo "ERROR: uv not found; is the uv SDK installed?" >&2; return 1; }
    uv_bin="$(command -v uv)"
    [ -f "$req" ] || { echo "ERROR: requirements file not found: $req" >&2; return 1; }
    marker="$venv/.requirements-sha256"
    sum="$(sha256sum "$req" | awk '{print $1}')"
    if ! { [ -x "$venv/bin/tox" ] && [ -f "$marker" ] && [ "$(cat "$marker")" = "$sum" ]; }; then
        rm -rf "$venv"
        UV_PYTHON_DOWNLOADS=never "$uv_bin" venv -q --python /usr/bin/python3 "$venv" || return 1
        VIRTUAL_ENV="$venv" "$uv_bin" pip install -q --system-certs --require-hashes -r "$req" || return 1
        echo "$sum" > "$marker"
    fi
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$venv/bin/tox" "$HOME/.local/bin/tox"
}

# seed_atlassian_mcp - merge the Atlassian MCP server entry into the global
# opencode config (~/.config/opencode/opencode.jsonc) idempotently (D-9).
# Entry per https://opencode.ai/docs/mcp-servers/: mcp.servers.<name> with
# type remote + url; OAuth consent happens separately via
# `opencode mcp auth atlassian` (the browser callback reaches the workshop
# through the connected tunnel). An already-seeded file is left untouched.
seed_atlassian_mcp() {
    local config="$HOME/.config/opencode/opencode.jsonc"
    local desired='{"type": "remote", "url": "https://mcp.atlassian.com/v2/mcp"}'
    local current merged
    mkdir -p "$(dirname "$config")"
    [ -f "$config" ] && [ -s "$config" ] || printf '{\n}\n' > "$config"
    if ! current="$(jq -c '.mcp.servers.atlassian // empty' "$config")"; then
        echo "ERROR: $config is not jq-parseable; seed the atlassian MCP server by hand." >&2
        return 1
    fi
    [ "$current" = "$(jq -cn "$desired")" ] && return 0
    merged="$(jq --argjson server "$desired" '.mcp.servers.atlassian = $server' "$config")"
    printf '%s\n' "$merged" > "$config"
}

# install_agentic_skills - clone canonical/openstack-agentic-skills into
# ~/.config/opencode/openstack-agentic-skills (or fast-forward an existing
# clone) and symlink it at ~/.config/opencode/skills/openstack-agentic-skills,
# per the repo README's OpenCode install. Never resets local changes.
install_agentic_skills() {
    local repo="https://github.com/canonical/openstack-agentic-skills"
    local dest="$HOME/.config/opencode/openstack-agentic-skills"
    local link_dir="$HOME/.config/opencode/skills"
    mkdir -p "$link_dir"
    if [ -d "$dest/.git" ]; then
        git -C "$dest" pull --ff-only \
            || echo "WARNING: could not fast-forward $dest; keeping the existing clone." >&2
    elif [ -e "$dest" ]; then
        echo "ERROR: $dest exists but is not a git clone; refusing to clobber it." >&2
        return 1
    else
        git clone "$repo" "$dest" || return 1
    fi
    ln -sfn "$dest" "$link_dir/openstack-agentic-skills"
}

# pin_forge_host_keys - pin ssh host keys for github.com, review.opendev.org
# and git.launchpad.net via scripts/pin-host-keys.sh (generalized from
# ck8s-dev's pin-github-host-keys.sh; fails loudly on a fingerprint
# mismatch - MITM guard). The missing-script guard keeps setup-project
# converging in partial checkouts where the secrets work item is absent.
pin_forge_host_keys() {
    local script="${1:-/project/scripts/pin-host-keys.sh}"
    if [ ! -f "$script" ]; then
        echo "WARNING: $script is missing; skipping host-key pinning." >&2
        return 0
    fi
    bash "$script" all
}

# find_vars_doc <profile> - locate this instance's merged vars doc
# (/project/.state/<name>.vars.json, persisted by scripts/setup.sh on the
# host before launch). The hook environment does not carry the workshop name
# (the runtime-hook contract provides only $SDK, $HOME, $XDG_RUNTIME_DIR and
# $DBUS_SESSION_BUS_ADDRESS), but the kernel hostname IS the bare workshop
# name - upstream canonical/workshop templates /etc/hostname from
# user.workshop.name (<WORKSHOP>.<PROJECT>.wp is only the DNS-level friendly
# name) - so the primary lookup keys on $(hostname). When it misses (e.g. a
# manual `just render <name> && just launch <name>` with no persisted vars
# doc), fall back to scanning the state dir for vars docs of this profile:
# exactly one match prints its path. Prints the resolved path on stdout and
# returns 0; returns 1 when there is no match or the profile scan is
# ambiguous - the caller warns and skips identity-dependent steps, never
# aborts. SUNBEAM_WORKSHOP_STATE_DIR overrides the state dir (the test
# suite uses it to point at a fixture dir).
find_vars_doc() {
    local profile="${1:?find_vars_doc needs a profile name}"
    local state_dir="${SUNBEAM_WORKSHOP_STATE_DIR:-/project/.state}"
    local by_host doc
    local -a matches=()
    by_host="${state_dir}/$(hostname).vars.json"
    if [ -f "$by_host" ]; then
        printf '%s\n' "$by_host"
        return 0
    fi
    for doc in "${state_dir}"/*.vars.json; do
        [ -f "$doc" ] || continue
        if [ "$(jq -r '.profile // empty' "$doc")" = "$profile" ]; then
            matches+=("$doc")
        fi
    done
    if [ "${#matches[@]}" -eq 1 ]; then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    return 1
}

# apply_git_identity <vars-doc-path> - set the workshop user's git identity
# from the merged vars doc (/project/.state/<name>.vars.json):
#   .user.name  -> git config --global user.name
#   .user.email -> git config --global user.email (when non-null)
# plus every entry of an optional .profile_vars.git object
# (e.g. "gitreview.username" for the charmed profile).
apply_git_identity() {
    local vars_doc="${1:?apply_git_identity needs a vars doc path}"
    local name email key value
    [ -f "$vars_doc" ] || { echo "ERROR: vars doc not found: $vars_doc" >&2; return 1; }
    name="$(jq -r '.user.name // empty' "$vars_doc")"
    email="$(jq -r '.user.email // empty' "$vars_doc")"
    [ -z "$name" ] || git config --global user.name "$name"
    [ -z "$email" ] || git config --global user.email "$email"
    if jq -e '.profile_vars.git | type == "object"' "$vars_doc" >/dev/null 2>&1; then
        while IFS=$'\t' read -r key value; do
            git config --global "$key" "$value"
        done < <(jq -r '.profile_vars.git | to_entries[] | "\(.key)\t\(.value)"' "$vars_doc")
    fi
}

# run_step <label> <cmd...> - run one provisioning step loudly but
# non-fatally: a failure prints an ERROR and the hook continues, because
# check-health is the authoritative gate and names the missing piece via
# workshopctl set-health --code (ck8s-dev setup-project.base pattern - a
# swallowed failure once left a "ready" workshop without its tooling).
# Relocated verbatim from the per-profile setup-project hooks, where it was
# defined identically three times.
run_step() {
    local label="$1"
    shift
    if ! "$@"; then
        echo "ERROR: ${label} failed; check-health will report it" >&2
    fi
}

# run_user_fragments <hook> <profile> - source user lifecycle fragments from
# ${SUNBEAM_WORKSHOP_FRAGMENT_ROOT:-/project/config/local/hooks}: for each
# scope in order (all, then <profile>, then $(hostname)) every
# "<root>/<scope>/<hook>.d/*.sh" file is sourced in lexical order inside its
# own subshell, so a fragment's exit or `set -e` death cannot kill the
# sourcing hook (fragments are user code; the subshell is the containment,
# and the subshell still sees every helper defined here). Non-.sh files and
# missing/empty dirs are a silent no-op. Per-fragment start/fail lines go to
# stderr. Failed fragment basenames (without .sh) collect in the global
# USER_FRAGMENT_FAILURES array; returns 1 when any fragment failed, else 0.
# setup-project calls this through run_step (fail-soft, last step);
# check-health calls it fail-hard immediately before its final set-health
# okay. setup-base can never have fragments: it runs pre-mount, when
# /project is not mounted.
run_user_fragments() {
    local hook="${1:?run_user_fragments needs a hook name}"
    local profile="${2:?run_user_fragments needs a profile name}"
    local root="${SUNBEAM_WORKSHOP_FRAGMENT_ROOT:-/project/config/local/hooks}"
    local scope dir fragment base
    USER_FRAGMENT_FAILURES=()
    for scope in all "$profile" "$(hostname)"; do
        dir="$root/$scope/$hook.d"
        [ -d "$dir" ] || continue
        for fragment in "$dir"/*.sh; do
            [ -f "$fragment" ] || continue
            base="$(basename "$fragment" .sh)"
            echo "user fragment: sourcing $scope/$hook.d/$base.sh" >&2
            if ! (
                # shellcheck disable=SC1090
                . "$fragment"
            ); then
                echo "ERROR: user fragment $scope/$hook.d/$base.sh failed; recorded in USER_FRAGMENT_FAILURES" >&2
                USER_FRAGMENT_FAILURES+=("$base")
            fi
        done
    done
    [ "${#USER_FRAGMENT_FAILURES[@]}" -eq 0 ]
}

# run_once <marker> - idempotency guard for fragments and other one-shot
# steps: returns 0 the first time it is called with a marker (recording it
# under ${XDG_STATE_HOME:-$HOME/.local/state}/sunbeam-workshop/run-once/)
# and 1 on every later call, so a re-run hook does not duplicate one-shot
# work.
run_once() {
    local marker="${1:?run_once needs a marker name}"
    local dir="${XDG_STATE_HOME:-$HOME/.local/state}/sunbeam-workshop/run-once"
    mkdir -p "$dir"
    if [ -e "$dir/$marker" ]; then
        return 1
    fi
    : > "$dir/$marker"
    return 0
}

# as_workshop_user <cmd...> - run a command as the workshop user (uid 1000)
# via sudo -u. For root-context fragments (check-health) that must act on
# the workshop user's environment; setup-project already runs as that user
# and never needs this.
as_workshop_user() {
    local workshop_user
    workshop_user="$(getent passwd 1000 | cut -d: -f1)"
    [ -n "$workshop_user" ] || {
        echo "ERROR: unable to resolve workshop user for uid 1000" >&2
        return 1
    }
    sudo -u "$workshop_user" "$@"
}
