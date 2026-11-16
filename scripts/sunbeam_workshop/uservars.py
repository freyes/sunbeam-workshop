"""User vars layers: config/local/vars/ discovery, strict schema, strict merge.

Three optional layer slots customize a workshop instance without touching the
tracked profile vars, in scope order (later slots win where merge semantics
are by-name):

    config/local/vars/all.{json,yaml}                every workshop
    config/local/vars/profile/<profile>.{json,yaml}  one profile
    config/local/vars/instance/<name>.{json,yaml}    one instance

Each slot is a format-flexible data doc loaded with loader.load_doc: exactly
one of .json or .yaml per slot. Coexistence, parse, and top-level-shape
failures raise loader.DocError naming the path. Schema violations raise
UserVarsError - a distinct class, because doc loading and schema validation
are different error classes (doc-loading is the loader's job; the strict
schema belongs to this module).

Strict schema (unknown keys are hard errors, never ignored):

    sdks.add:     list of entries; each requires name (non-empty string) and
                  allows only channel (string), plugs (list of strings),
                  slots (list of strings). Optional keys set to null count
                  as absent.
    sdks.set:     mapping of sdk name to a dict containing exactly one key,
                  channel, with a string value.
    sdks.remove:  list of sdk-name strings.
    actions:      mapping of action name to body string; names must match
                  ^[a-z](?:-?[a-z0-9])*$ (pattern only, no length cap - A7).

Merge across docs in scope order: sdks.add concatenates; sdks.set merges by
name (later doc wins); sdks.remove unions preserving first-seen order;
actions merge by name (later doc wins) with one warning per override naming
both the overriding and the overridden path.

Kill-switch (assumption A1): when the SUNBEAM_WORKSHOP_NO_USER_LAYERS
environment variable is set to a non-empty value other than "0", discover()
returns [] and user layers are ignored entirely. The golden/equivalence
suites export it so a dev machine's local layers cannot false-fail renders.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, NotRequired, TypedDict

from .loader import LoadedDoc, load_doc

KILL_SWITCH_ENV = "SUNBEAM_WORKSHOP_NO_USER_LAYERS"
ACTION_NAME_PATTERN = re.compile(r"^[a-z](?:-?[a-z0-9])*$")

TOP_LEVEL_KEYS = frozenset({"sdks", "actions"})
SDKS_KEYS = frozenset({"add", "set", "remove"})
ADD_ENTRY_KEYS = frozenset({"name", "channel", "plugs", "slots"})
SET_ENTRY_KEYS = frozenset({"channel"})


class UserVarsError(Exception):
    """A user vars layer violates the strict schema (message: path + key)."""


class SdkAdd(TypedDict):
    """One validated sdks.add entry; name is required, the rest optional."""

    name: str
    channel: NotRequired[str]
    plugs: NotRequired[list[str]]
    slots: NotRequired[list[str]]


class SdkSet(TypedDict):
    """One validated sdks.set entry; channel is the only supported key."""

    channel: str


@dataclass(frozen=True)
class UserVars:
    """Validated, merged user vars. Containers are built, then frozen."""

    sdks_add: list[SdkAdd] = field(default_factory=list)
    sdks_set: dict[str, SdkSet] = field(default_factory=dict)
    sdks_remove: list[str] = field(default_factory=list)
    actions: dict[str, str] = field(default_factory=dict)


def layer_paths(root: Path, profile: str, name: str) -> list[tuple[Path, str]]:
    """User vars slot base paths (suffix-less) + purposes, in scope order."""
    vars_dir = root / "config" / "local" / "vars"
    return [
        (vars_dir / "all", "user vars layer (all)"),
        (vars_dir / "profile" / profile, f"user vars layer for profile {profile!r}"),
        (vars_dir / "instance" / name, f"user vars layer for instance {name!r}"),
    ]


def discover(root: Path, profile: str, name: str) -> list[LoadedDoc]:
    """Load the user vars layers for (profile, name), in scope order.

    Kill-switch (assumption A1): when SUNBEAM_WORKSHOP_NO_USER_LAYERS is set
    to a non-empty value other than "0", return [] - user layers are ignored
    entirely. Absent slots are skipped. loader.DocError (coexistence, parse,
    top-level shape) propagates; its messages already name the paths.
    """
    kill_switch = os.environ.get(KILL_SWITCH_ENV, "")
    if kill_switch not in ("", "0"):
        return []
    docs: list[LoadedDoc] = []
    for base, purpose in layer_paths(root, profile, name):
        doc = load_doc(base, purpose)
        if doc is not None:
            docs.append(doc)
    return docs


def validate_layer(doc: LoadedDoc) -> None:
    """Strictly validate one layer doc; raise UserVarsError on any violation.

    Every message names doc.path and the dotted key path of the offender
    (e.g. ``sdks.set.uv.channel must be a string``).
    """
    _parse_layer(doc)


def merge(docs: list[LoadedDoc]) -> tuple[UserVars, list[str]]:
    """Validate every doc, then merge in scope order.

    sdks.add concatenates across docs; sdks.set merges by name (later doc
    wins); sdks.remove unions preserving first-seen order; actions merge by
    name (later doc wins) with one warning per override naming both paths.
    """
    parsed = [(doc, _parse_layer(doc)) for doc in docs]
    sdks_add: list[SdkAdd] = []
    sdks_set: dict[str, SdkSet] = {}
    sdks_remove: list[str] = []
    remove_seen: set[str] = set()
    actions: dict[str, str] = {}
    action_sources: dict[str, Path] = {}
    warnings: list[str] = []
    for doc, layer in parsed:
        sdks_add.extend(layer.sdks_add)
        sdks_set.update(layer.sdks_set)
        for name in layer.sdks_remove:
            if name not in remove_seen:
                remove_seen.add(name)
                sdks_remove.append(name)
        for action, body in layer.actions.items():
            if action in actions:
                warnings.append(
                    f"action '{action}' from {doc.path} overrides earlier "
                    f"definition from {action_sources[action]}"
                )
            actions[action] = body
            action_sources[action] = doc.path
    return (
        UserVars(
            sdks_add=sdks_add,
            sdks_set=sdks_set,
            sdks_remove=sdks_remove,
            actions=actions,
        ),
        warnings,
    )


def _parse_layer(doc: LoadedDoc) -> UserVars:
    """Parse + strictly validate one layer doc into a per-doc UserVars."""
    data = doc.data
    for key in data:
        if key not in TOP_LEVEL_KEYS:
            raise UserVarsError(f"{doc.path}: unknown top-level key {key!r}")
    sdks_add: list[SdkAdd] = []
    sdks_set: dict[str, SdkSet] = {}
    sdks_remove: list[str] = []
    actions: dict[str, str] = {}
    if "sdks" in data:
        sdks_add, sdks_set, sdks_remove = _parse_sdks(doc, data["sdks"])
    if "actions" in data:
        actions = _parse_actions(doc, data["actions"])
    return UserVars(
        sdks_add=sdks_add,
        sdks_set=sdks_set,
        sdks_remove=sdks_remove,
        actions=actions,
    )


def _parse_sdks(
    doc: LoadedDoc, raw: Any
) -> tuple[list[SdkAdd], dict[str, SdkSet], list[str]]:
    if not isinstance(raw, dict):
        raise UserVarsError(f"{doc.path}: sdks must be a dict")
    for key in raw:
        if key not in SDKS_KEYS:
            raise UserVarsError(f"{doc.path}: unknown sdks key {key!r}")
    add: list[SdkAdd] = []
    sdk_set: dict[str, SdkSet] = {}
    remove: list[str] = []
    if "add" in raw:
        add = _parse_add(doc, raw["add"])
    if "set" in raw:
        sdk_set = _parse_set(doc, raw["set"])
    if "remove" in raw:
        remove = _parse_remove(doc, raw["remove"])
    return add, sdk_set, remove


def _parse_add(doc: LoadedDoc, raw: Any) -> list[SdkAdd]:
    if not isinstance(raw, list):
        raise UserVarsError(f"{doc.path}: sdks.add must be a list")
    entries: list[SdkAdd] = []
    for index, entry in enumerate(raw):
        where = f"sdks.add[{index}]"
        if not isinstance(entry, dict):
            raise UserVarsError(f"{doc.path}: {where} must be a dict")
        for key in entry:
            if key not in ADD_ENTRY_KEYS:
                raise UserVarsError(f"{doc.path}: {where}: unknown key {key!r}")
        if "name" not in entry:
            raise UserVarsError(f"{doc.path}: {where}.name is required")
        name = entry["name"]
        if not isinstance(name, str) or not name:
            raise UserVarsError(f"{doc.path}: {where}.name must be a non-empty string")
        parsed: SdkAdd = {"name": name}
        channel = entry.get("channel")
        if channel is not None:
            if not isinstance(channel, str):
                raise UserVarsError(f"{doc.path}: {where}.channel must be a string")
            parsed["channel"] = channel
        plugs = entry.get("plugs")
        if plugs is not None:
            parsed["plugs"] = _parse_string_list(doc, f"{where}.plugs", plugs)
        slots = entry.get("slots")
        if slots is not None:
            parsed["slots"] = _parse_string_list(doc, f"{where}.slots", slots)
        entries.append(parsed)
    return entries


def _parse_set(doc: LoadedDoc, raw: Any) -> dict[str, SdkSet]:
    if not isinstance(raw, dict):
        raise UserVarsError(f"{doc.path}: sdks.set must be a dict")
    parsed: dict[str, SdkSet] = {}
    for name, entry in raw.items():
        if not isinstance(name, str):
            raise UserVarsError(
                f"{doc.path}: sdks.set: entry name must be a string, got {name!r}"
            )
        where = f"sdks.set.{name}"
        if not isinstance(entry, dict):
            raise UserVarsError(f"{doc.path}: {where} must be a dict")
        for key in entry:
            if key not in SET_ENTRY_KEYS:
                raise UserVarsError(f"{doc.path}: {where}: unknown key {key!r}")
        if "channel" not in entry:
            raise UserVarsError(f"{doc.path}: {where}.channel is required")
        channel = entry["channel"]
        if not isinstance(channel, str):
            raise UserVarsError(f"{doc.path}: {where}.channel must be a string")
        parsed[name] = {"channel": channel}
    return parsed


def _parse_remove(doc: LoadedDoc, raw: Any) -> list[str]:
    if not isinstance(raw, list):
        raise UserVarsError(f"{doc.path}: sdks.remove must be a list")
    for index, item in enumerate(raw):
        if not isinstance(item, str):
            raise UserVarsError(f"{doc.path}: sdks.remove[{index}] must be a string")
    return list(raw)


def _parse_actions(doc: LoadedDoc, raw: Any) -> dict[str, str]:
    if not isinstance(raw, dict):
        raise UserVarsError(f"{doc.path}: actions must be a dict")
    parsed: dict[str, str] = {}
    for name, body in raw.items():
        if not isinstance(name, str) or not ACTION_NAME_PATTERN.fullmatch(name):
            raise UserVarsError(
                f"{doc.path}: actions.{name}: invalid action name "
                f"(must match {ACTION_NAME_PATTERN.pattern})"
            )
        if not isinstance(body, str):
            raise UserVarsError(f"{doc.path}: actions.{name} must be a string")
        parsed[name] = body
    return parsed


def _parse_string_list(doc: LoadedDoc, where: str, value: Any) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise UserVarsError(f"{doc.path}: {where} must be a list of strings")
    return list(value)
