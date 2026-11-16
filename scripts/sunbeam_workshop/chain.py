"""SDK chain assembly: base chain + profile extra_sdks + user customization.

The chain every profile shares (profiles/_partials/sdks-chain.yaml.j2, draft
D-3) is assembled here in Python (plan decision: "chain assembly moves to
Python, sdks-chain.yaml.j2 becomes a dumb emitter"). Final order:

    BASE_CHAIN -> profile extra_sdks -> user sdks.add -> project-<p>-tools

User customization rules (locked decisions 2 and 4):

* sdks.remove: the base chain and the project SDK are PROTECTED - removing
  one is a hard error. Removable names are exactly the profile extra_sdks and
  user-added entries; removing any other (unknown) name is a hard error.
* sdks.set is channel-only (pre-validated by uservars). Setting a channel on
  a project-*, try-*, or system SDK is schema-inert (the vendored schema:
  channel "only applies to SDKs from the Store; for try-, project-, and
  system SDKs the value has no effect") and is a hard error. Setting gh-cli
  or openchamber is allowed but appends a load-bearing warning (credentials
  wiring and the :3000 UI ride on those SDKs). Setting a name absent from
  the final chain is a hard error (assumption A2: a silent no-op masks
  typos).
* Duplicate names in the final chain are a hard error.

All failures raise uservars.UserVarsError so the CLI reports one error
class for the whole user-customization surface.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .uservars import UserVars, UserVarsError

# The exact entries of profiles/_partials/sdks-chain.yaml.j2, in order:
# opencode (no channel), openchamber@latest/edge (must follow opencode),
# gh-cli (no channel), uv@latest/stable. A "channel" key is present only
# when the partial renders one.
BASE_CHAIN: list[dict[str, Any]] = [
    {"name": "opencode"},
    {"name": "openchamber", "channel": "latest/edge"},
    {"name": "gh-cli"},
    {"name": "uv", "channel": "latest/stable"},
]

BASE_NAMES: tuple[str, ...] = tuple(entry["name"] for entry in BASE_CHAIN)

# sdks.set on these store SDKs is allowed but load-bearing (decision 4).
LOAD_BEARING_REASONS: dict[str, str] = {
    "gh-cli": (
        "the gh-cli SDK delivers host-keyring credentials through the "
        "github-token secret plug; a channel change can break authentication"
    ),
    "openchamber": (
        "the openchamber SDK serves the workshop UI on :3000; a channel "
        "change can break the UI"
    ),
}


@dataclass(frozen=True)
class ChainDiff:
    """Name-level diff of the final chain vs the default (no user input)."""

    added: list[str] = field(default_factory=list)
    overridden: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)


def project_sdk_name(profile: str) -> str:
    """The in-project SDK name every profile chain ends with."""
    return f"project-{profile}-tools"


def protected_names(profile: str) -> frozenset[str]:
    """SDK names sdks.remove can never drop: base chain + the project SDK."""
    return frozenset((*BASE_NAMES, project_sdk_name(profile)))


def _copy(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Shallow-copy chain entries so callers' data is never mutated."""
    return [dict(entry) for entry in entries]


def build_chain(
    profile: str, profile_vars: dict[str, Any], user_vars: UserVars
) -> tuple[list[dict[str, Any]], ChainDiff, list[str]]:
    """Assemble the final SDK chain; returns (chain, diff, warnings).

    ``profile_vars`` is the tracked profile vars doc (extra_sdks defaults to
    []); ``user_vars`` is the merged, validated user customization. Raises
    UserVarsError on any rule violation.
    """
    project_sdk = project_sdk_name(profile)
    protected = protected_names(profile)
    extra_sdks = profile_vars.get("extra_sdks") or []

    default_chain = [
        *_copy(BASE_CHAIN),
        *_copy(extra_sdks),
        {"name": project_sdk},
    ]
    chain = [
        *_copy(BASE_CHAIN),
        *_copy(extra_sdks),
        *_copy(user_vars.sdks_add),
        {"name": project_sdk},
    ]

    # sdks.remove: protected names and unknown names are hard errors;
    # removable = profile extra_sdks + user-added entries (decision 2).
    removable = {entry["name"] for entry in extra_sdks} | {
        entry["name"] for entry in user_vars.sdks_add
    }
    for name in user_vars.sdks_remove:
        if name in protected:
            raise UserVarsError(
                f"sdks.remove: {name!r} is protected (the base chain and "
                f"{project_sdk} cannot be removed)"
            )
        if name not in removable:
            raise UserVarsError(
                f"sdks.remove: unknown SDK {name!r} (removable: profile "
                "extra_sdks and user-added SDKs only)"
            )
    for name in user_vars.sdks_remove:
        chain = [entry for entry in chain if entry["name"] != name]

    # sdks.set: channel-only, store SDKs only (decision 4).
    warnings: list[str] = []
    for name, entry in user_vars.sdks_set.items():
        if name == "system" or name.startswith(("project-", "try-")):
            raise UserVarsError(
                f"sdks.set.{name}: channel is schema-inert on project-, "
                "try-, and system SDKs (it only applies to SDKs from the "
                "Store); remove the entry"
            )
        for chain_entry in chain:
            if chain_entry["name"] == name:
                chain_entry["channel"] = entry["channel"]
                break
        else:
            raise UserVarsError(
                f"sdks.set.{name}: no SDK named {name!r} in the final chain"
            )
        if name in LOAD_BEARING_REASONS:
            warnings.append(
                f"sdks.set.{name}: channel override is load-bearing - "
                f"{LOAD_BEARING_REASONS[name]}"
            )

    # Duplicate names in the final chain are a hard error.
    seen: set[str] = set()
    for entry in chain:
        name = entry["name"]
        if name in seen:
            raise UserVarsError(
                f"sdks chain: duplicate SDK name {name!r} "
                "(a user sdks.add entry clashes with an existing entry)"
            )
        seen.add(name)

    # Diff vs the default chain (no user input), by name.
    default_names = [entry["name"] for entry in default_chain]
    final_names = [entry["name"] for entry in chain]
    default_channels = {
        entry["name"]: entry.get("channel") for entry in default_chain
    }
    diff = ChainDiff(
        added=[name for name in final_names if name not in default_names],
        overridden=[
            entry["name"]
            for entry in chain
            if entry["name"] in default_channels
            and entry.get("channel") != default_channels[entry["name"]]
        ],
        removed=[name for name in default_names if name not in final_names],
    )
    return chain, diff, warnings
