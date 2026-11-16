"""The `layers` report: read-only visibility into user customization.

`just layers <name>` (CLI: ``python -m sunbeam_workshop layers NAME``) prints
what customizes one workshop instance without changing anything:

* name resolution (profile, suffix) via vars.resolve_name;
* the applied user vars layers (uservars.discover) with path, format, and a
  short digest, plus the state of the SUNBEAM_WORKSHOP_NO_USER_LAYERS
  kill-switch (assumption A1);
* the effective SDK chain diff vs the default chain (chain.build_chain over
  the profile vars and the merged user vars): added/overridden/removed;
* the merged actions (names only) with the layer each came from;
* discovered hook fragments under
  config/local/hooks/{all,<profile>,<instance>}/{setup-project,check-health}.d/*.sh
  (paths only; fragment content is never read);
* discovered user SDKs: .workshop/*-user-tools/ directories plus any
  sdks.add entries named project-*;
* drift vs the persisted vars doc .state/<name>.vars.json: when it carries
  `_layers` provenance (assumption A3), recorded digests are compared
  against the current layer digests so an edited layer is NAMED, never
  silently stale. A missing state doc is reported, not an error.
  SUNBEAM_WORKSHOP_STATE_DIR overrides the state dir (mirrors
  scripts/hooks/lib-common.sh; the test suite uses it for fixture state).

This module only READS loader/uservars/chain/vars; it changes no behavior.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from .chain import build_chain
from .loader import LoadedDoc
from .uservars import KILL_SWITCH_ENV, UserVars, discover, merge
from .vars import load_profile_vars_doc, resolve_name

STATE_DIR_ENV = "SUNBEAM_WORKSHOP_STATE_DIR"
SHORT_DIGEST = 12
# The two hooks that run user fragments (design: setup-base and the
# save/restore pair are excluded - pre-mount physical / not requested).
FRAGMENT_HOOKS = ("setup-project", "check-health")
USER_SDK_SUFFIX = "-user-tools"


def _display(root: Path, path: Path) -> str:
    """Root-relative path when possible, so reports stay checkout-agnostic."""
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def _kill_switch_active() -> bool:
    """Mirror of the discover() kill-switch predicate (assumption A1)."""
    return os.environ.get(KILL_SWITCH_ENV, "") not in ("", "0")


def _layer_entry(kind: str, doc: LoadedDoc) -> dict[str, str]:
    """One provenance entry; same shape as the persisted `_layers` (A3)."""
    return {
        "kind": kind,
        "path": str(doc.path),
        "format": doc.format,
        "digest": doc.digest,
    }


def _discover_fragments(root: Path, profile: str, name: str) -> list[Path]:
    """Fragment paths in run order: scope all -> profile -> instance, then
    hook, then lexical. Paths only; content is never read. An unsuffixed
    instance's profile and instance scope dirs coincide and are deduped."""
    hooks_root = root / "config" / "local" / "hooks"
    fragments: list[Path] = []
    seen: set[Path] = set()
    for scope in ("all", profile, name):
        for hook in FRAGMENT_HOOKS:
            fragment_dir = hooks_root / scope / f"{hook}.d"
            if not fragment_dir.is_dir():
                continue
            for path in sorted(fragment_dir.glob("*.sh")):
                if path not in seen:
                    seen.add(path)
                    fragments.append(path)
    return fragments


def _discover_user_sdks(root: Path, user_vars: UserVars) -> tuple[list[Path], list[str]]:
    """User-owned SDKs: .workshop/*-user-tools/ dirs (gitignored) plus any
    sdks.add entries named project-* (the user-SDK pattern from the design:
    an in-project SDK carried by a user layer)."""
    workshop_dir = root / ".workshop"
    dirs: list[Path] = []
    if workshop_dir.is_dir():
        dirs = sorted(
            entry
            for entry in workshop_dir.glob(f"*{USER_SDK_SUFFIX}")
            if entry.is_dir()
        )
    add_entries = [
        entry["name"] for entry in user_vars.sdks_add if entry["name"].startswith("project-")
    ]
    return dirs, add_entries


def _drift_lines(root: Path, name: str, current: list[dict[str, str]]) -> list[str]:
    """Compare current layer digests against the persisted `_layers` (A3).

    Missing state doc, unparseable JSON, or an absent `_layers` key are all
    REPORTED, never raised: the state dir is runtime state, and drift
    detection must not fail an otherwise healthy report.
    """
    override = os.environ.get(STATE_DIR_ENV) or None
    state_dir = Path(override) if override else root / ".state"
    state_path = state_dir / f"{name}.vars.json"
    shown = _display(root, state_path)
    if not state_path.is_file():
        return [
            f"{shown}: no persisted vars doc; nothing to compare. "
            f"Run `just setup {name}` to create one."
        ]
    try:
        persisted: Any = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return [f"{shown}: could not parse the persisted vars doc ({exc}); drift check skipped."]
    if not isinstance(persisted, dict) or not isinstance(persisted.get("_layers"), list):
        return [
            f"{shown}: no _layers provenance recorded (persisted by an older "
            f"version?). Re-run `just setup {name}` to record it."
        ]
    recorded_by_path = {
        str(entry.get("path", "")): str(entry.get("digest", ""))
        for entry in persisted["_layers"]
        if isinstance(entry, dict)
    }
    current_by_path = {entry["path"]: entry["digest"] for entry in current}
    drifted: list[str] = []
    for path, digest in recorded_by_path.items():
        shown_path = _display(root, Path(path))
        if path not in current_by_path:
            drifted.append(f"{shown_path}: recorded but no longer applied")
        elif current_by_path[path] != digest:
            drifted.append(f"{shown_path}: content changed since the last `just setup {name}`")
    for path in current_by_path:
        if path not in recorded_by_path:
            drifted.append(f"{_display(root, Path(path))}: applied but not recorded")
    if not drifted:
        return [f"{shown}: in sync ({len(current)} layer digest(s) match)"]
    lines = [f"{shown}: DRIFT - {len(drifted)} layer(s) differ from the persisted digests:"]
    lines.extend(f"  - {line}" for line in drifted)
    lines.append(f"Re-run `just setup {name}` to re-render with the current layers.")
    return lines


def build_report(root: Path, name: str) -> str:
    """The human-readable layers report for workshop NAME rooted at root.

    Raises vars.VarsError (name resolution), loader.DocError (data doc
    loading), and uservars.UserVarsError (strict schema / chain rules) -
    the CLI maps them onto the existing exit-code pattern.
    """
    resolution = resolve_name(root, name)
    profile = resolution.profile
    profile_doc = load_profile_vars_doc(root, profile)
    profile_vars = profile_doc.data if profile_doc is not None else {}
    kill_active = _kill_switch_active()
    user_docs = discover(root, profile, resolution.name)
    user_vars, merge_warnings = merge(user_docs)
    _chain, chain_diff, chain_warnings = build_chain(profile, profile_vars, user_vars)

    # Merged actions (names only) with the layer each came from; user layers
    # win over the profile vars and over each other in scope order. merge()
    # has already validated every doc, so doc.data is safe to read here.
    warnings = [*merge_warnings, *chain_warnings]
    action_sources: dict[str, str] = {}
    if profile_doc is not None:
        profile_shown = f"profile vars ({_display(root, profile_doc.path)})"
        for action_name in profile_vars.get("actions", {}):
            action_sources[action_name] = profile_shown
    for doc in user_docs:
        for action_name in doc.data.get("actions", {}):
            if action_name in action_sources and action_sources[action_name].startswith(
                "profile vars"
            ):
                warnings.append(
                    f"action '{action_name}' from user layer overrides profile action"
                )
            action_sources[action_name] = f"user layer ({_display(root, doc.path)})"

    fragments = _discover_fragments(root, profile, resolution.name)
    user_sdk_dirs, user_sdk_adds = _discover_user_sdks(root, user_vars)
    current_layers = [
        *([_layer_entry("profile", profile_doc)] if profile_doc is not None else []),
        *(_layer_entry("user", user_doc) for user_doc in user_docs),
    ]

    lines: list[str] = []
    suffix = f", suffix: {resolution.suffix}" if resolution.suffix else ", no suffix"
    lines.append(f"layers report for workshop '{resolution.name}' (profile: {profile}{suffix})")
    if resolution.shadow_warning:
        lines.append(
            "  warning: profiles/ and .workshop/ both hold this name; "
            "the profile shadows the launched instance (D-13)"
        )

    lines.append("")
    lines.append("== User vars layers")
    state = "ACTIVE (user layers ignored)" if kill_active else "inactive"
    lines.append(f"kill-switch {KILL_SWITCH_ENV}: {state}")
    if not user_docs:
        lines.append("  (no user layers applied)")
    for doc in user_docs:
        lines.append(
            f"  - {_display(root, doc.path)} "
            f"[{doc.format}, sha256:{doc.digest[:SHORT_DIGEST]}]"
        )

    lines.append("")
    lines.append("== SDK chain diff vs the default chain")
    if not (chain_diff.added or chain_diff.overridden or chain_diff.removed):
        lines.append("  (no changes; the effective chain is the default)")
    else:
        lines.append(f"  added: {', '.join(chain_diff.added) or '-'}")
        lines.append(f"  overridden: {', '.join(chain_diff.overridden) or '-'}")
        lines.append(f"  removed: {', '.join(chain_diff.removed) or '-'}")

    lines.append("")
    lines.append("== Actions")
    if not action_sources:
        lines.append("  (none defined)")
    for action_name, source in action_sources.items():
        lines.append(f"  - {action_name} ({source})")

    lines.append("")
    lines.append("== Hook fragments")
    if not fragments:
        lines.append("  (none discovered under config/local/hooks/)")
    for path in fragments:
        lines.append(f"  - {_display(root, path)}")

    lines.append("")
    lines.append("== User SDKs")
    if not user_sdk_dirs and not user_sdk_adds:
        lines.append("  (none discovered)")
    for path in user_sdk_dirs:
        lines.append(f"  - {_display(root, path)}/ (user-owned in-project SDK)")
    for sdk_name in user_sdk_adds:
        lines.append(f"  - {sdk_name} (sdks.add entry from user layers)")

    lines.append("")
    lines.append("== Drift vs the persisted vars doc")
    lines.extend(f"  {line}" for line in _drift_lines(root, resolution.name, current_layers))

    if warnings:
        lines.append("")
        lines.append("== Warnings")
        lines.extend(f"  - {warning}" for warning in warnings)

    return "\n".join(lines) + "\n"
