"""Resolve a workshop NAME to (profile, suffix) and emit the merged vars doc.

Name rules and resolution (draft decision D-13):

* NAME must match ``^[a-z](?:-?[a-z0-9])*$`` and be at most 40 chars.
* An exact profile dir match (``profiles/<NAME>/``) wins and yields an
  empty suffix; otherwise the longest hyphen-delimited prefix matching a
  dir under ``profiles/`` is the profile and the remainder is the
  instance suffix. Unknown prefixes fail and list the valid profiles.
* If ``.workshop/<NAME>/`` exists (a launched instance) and no exact
  profile dir shadows it, the name collides and is rejected.
* When both ``profiles/<NAME>/`` and ``.workshop/<NAME>/`` exist, the
  profile shadows the existing instance: resolution succeeds with
  ``shadow_warning=True`` (D-13: "warns when both exist").

The merged vars doc (D-14) contains: workshop_name, profile, suffix,
shadow_warning, profile vars (``profiles/<profile>/vars.json``, tolerated
as ``{}`` when absent), the merged config layers, and the user identity.
JSON only - no YAML data source.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import load_config

NAME_PATTERN = re.compile(r"^[a-z](?:-?[a-z0-9])*$")
NAME_MAX_LENGTH = 40


class VarsError(Exception):
    """Base class for vars-builder failures; exit_code is used by the CLI."""

    exit_code = 2


class UnknownProfileError(VarsError):
    """No profile dir matches NAME or a hyphen-prefix of it."""

    exit_code = 3


class InvalidNameError(VarsError):
    """NAME violates the workshop name rules."""

    exit_code = 4


class InstanceCollisionError(VarsError):
    """An instance named NAME already exists under .workshop/."""

    exit_code = 5


@dataclass(frozen=True)
class Resolution:
    name: str
    profile: str
    suffix: str
    shadow_warning: bool


def current_user() -> str:
    """Host user name, with any '@canonical.com' suffix stripped."""
    return os.environ.get("USER", "nobody").replace("@canonical.com", "")


def list_profiles(root: Path) -> list[str]:
    """Profile names discovered from directories under profiles/."""
    profiles_dir = root / "profiles"
    if not profiles_dir.is_dir():
        return []
    return sorted(entry.name for entry in profiles_dir.iterdir() if entry.is_dir())


def validate_name(name: str) -> None:
    """Enforce the workshop name rules on the full NAME."""
    if len(name) > NAME_MAX_LENGTH or not NAME_PATTERN.fullmatch(name):
        raise InvalidNameError(
            f"invalid workshop name {name!r}: must match {NAME_PATTERN.pattern} "
            f"and be at most {NAME_MAX_LENGTH} characters"
        )


def resolve_name(root: Path, name: str) -> Resolution:
    """Resolve NAME to (profile, suffix) applying the D-13 rules."""
    validate_name(name)
    instance_dir = root / ".workshop" / name
    if name in list_profiles(root):
        # Exact profile dir match. A launched instance of the same name is
        # shadowed by the profile: warn, do not reject (D-13).
        return Resolution(
            name=name, profile=name, suffix="", shadow_warning=instance_dir.is_dir()
        )
    if instance_dir.is_dir():
        raise InstanceCollisionError(
            f"workshop instance {name!r} already exists: {instance_dir} "
            f"collides with an existing .workshop/ directory"
        )
    candidates = [p for p in list_profiles(root) if name.startswith(p + "-")]
    if not candidates:
        valid = ", ".join(list_profiles(root)) or "(none)"
        raise UnknownProfileError(
            f"unknown profile for workshop name {name!r}; valid profiles: {valid}"
        )
    profile = max(candidates, key=len)
    return Resolution(
        name=name,
        profile=profile,
        suffix=name[len(profile) + 1 :],
        shadow_warning=False,
    )


def load_profile_vars(root: Path, profile: str) -> dict[str, Any]:
    """Profile vars from profiles/<profile>/vars.json; {} when absent."""
    path = root / "profiles" / profile / "vars.json"
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise VarsError(f"{path} must contain a JSON object")
    return data


def build_vars(root: Path, name: str, user: str | None = None) -> dict[str, Any]:
    """Build the merged vars doc for workshop NAME rooted at root."""
    resolution = resolve_name(root, name)
    user = current_user() if user is None else user
    config = load_config(root, user)
    return {
        "workshop_name": resolution.name,
        "profile": resolution.profile,
        "suffix": resolution.suffix,
        "shadow_warning": resolution.shadow_warning,
        "profile_vars": load_profile_vars(root, resolution.profile),
        "config": config,
        "user": {
            "name": user,
            "github_handle": config.get("github_handle"),
            "email": config.get("email"),
        },
    }


def find_root(start: Path) -> Path:
    """Repo root: the nearest ancestor of start holding profiles/ and config/."""
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / "profiles").is_dir() and (candidate / "config").is_dir():
            return candidate
    return current
