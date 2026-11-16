"""Tests for sunbeam_workshop.chain (SDK chain assembly).

The default-chain tests read the REAL profiles/*/vars.json from the repo
root so the assembled chain is pinned against the tracked profile data; the
rule tests use synthetic UserVars inputs.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from sunbeam_workshop.chain import (
    BASE_CHAIN,
    ChainDiff,
    build_chain,
    project_sdk_name,
    protected_names,
)
from sunbeam_workshop.uservars import UserVars, UserVarsError

REPO_ROOT = Path(__file__).resolve().parents[2]
REAL_PROFILES = ("sunbeam", "charmed", "packaging")
PROFILE = "sunbeam"


def real_profile_vars(profile: str) -> dict:
    """The tracked profiles/<profile>/vars.json from the repo root."""
    return json.loads(
        (REPO_ROOT / "profiles" / profile / "vars.json").read_text(encoding="utf-8")
    )


def expected_default(profile: str, profile_vars: dict) -> list[dict]:
    """Legacy chain order: BASE_CHAIN -> extra_sdks -> project-<p>-tools."""
    return [
        *[dict(entry) for entry in BASE_CHAIN],
        *[dict(entry) for entry in profile_vars.get("extra_sdks", [])],
        {"name": project_sdk_name(profile)},
    ]


# --- default chain == legacy order -----------------------------------------


def test_base_chain_pins_the_shared_partial_order() -> None:
    # The exact entries of profiles/_partials/sdks-chain.yaml.j2 (draft D-3).
    assert BASE_CHAIN == [
        {"name": "opencode"},
        {"name": "openchamber", "channel": "latest/edge"},
        {"name": "gh-cli"},
        {"name": "uv", "channel": "latest/stable"},
    ]


@pytest.mark.parametrize("profile", REAL_PROFILES)
def test_default_chain_matches_legacy_order(profile: str) -> None:
    profile_vars = real_profile_vars(profile)
    chain, diff, warnings = build_chain(profile, profile_vars, UserVars())
    assert chain == expected_default(profile, profile_vars)
    assert diff == ChainDiff(added=[], overridden=[], removed=[])
    assert warnings == []


@pytest.mark.parametrize("profile", REAL_PROFILES)
def test_default_chain_names_end_with_project_sdk(profile: str) -> None:
    chain, _, _ = build_chain(profile, real_profile_vars(profile), UserVars())
    names = [entry["name"] for entry in chain]
    assert names[:4] == ["opencode", "openchamber", "gh-cli", "uv"]
    assert names[-1] == f"project-{profile}-tools"
    if profile == "packaging":
        assert names[-2] == "orange-dev-tools"


def test_packaging_extra_sdks_land_between_uv_and_project_sdk() -> None:
    chain, _, _ = build_chain("packaging", real_profile_vars("packaging"), UserVars())
    names = [entry["name"] for entry in chain]
    assert names == [
        "opencode",
        "openchamber",
        "gh-cli",
        "uv",
        "orange-dev-tools",
        "project-packaging-tools",
    ]
    assert chain[4] == {"name": "orange-dev-tools", "channel": "latest/edge"}


def test_protected_names_are_base_chain_plus_project_sdk() -> None:
    assert protected_names(PROFILE) == frozenset(
        {"opencode", "openchamber", "gh-cli", "uv", "project-sunbeam-tools"}
    )


# --- sdks.remove ------------------------------------------------------------


@pytest.mark.parametrize(
    "name", ["opencode", "openchamber", "gh-cli", "uv", "project-sunbeam-tools"]
)
def test_remove_protected_rejected(name: str) -> None:
    user_vars = UserVars(sdks_remove=[name])
    with pytest.raises(UserVarsError, match="protected"):
        build_chain(PROFILE, {}, user_vars)


def test_remove_unknown_rejected() -> None:
    user_vars = UserVars(sdks_remove=["no-such-sdk"])
    with pytest.raises(UserVarsError, match="unknown SDK 'no-such-sdk'"):
        build_chain(PROFILE, {}, user_vars)


def test_remove_profile_extra_sdks_works() -> None:
    profile_vars = {"extra_sdks": [{"name": "orange-dev-tools", "channel": "e"}]}
    user_vars = UserVars(sdks_remove=["orange-dev-tools"])
    chain, diff, _ = build_chain(PROFILE, profile_vars, user_vars)
    assert "orange-dev-tools" not in [entry["name"] for entry in chain]
    assert diff.removed == ["orange-dev-tools"]
    assert diff.added == []


def test_remove_user_added_sdk_works() -> None:
    user_vars = UserVars(sdks_add=[{"name": "my-sdk"}], sdks_remove=["my-sdk"])
    chain, diff, _ = build_chain(PROFILE, {}, user_vars)
    assert [entry["name"] for entry in chain] == [
        *[entry["name"] for entry in BASE_CHAIN],
        "project-sunbeam-tools",
    ]
    assert diff == ChainDiff(added=[], overridden=[], removed=[])


def test_add_then_remove_same_name_stays_removable() -> None:
    # A user add makes the name removable even when the profile also has it.
    profile_vars = {"extra_sdks": [{"name": "extra-one"}]}
    user_vars = UserVars(sdks_add=[{"name": "extra-one"}], sdks_remove=["extra-one"])
    chain, _, _ = build_chain(PROFILE, profile_vars, user_vars)
    assert "extra-one" not in [entry["name"] for entry in chain]


# --- sdks.set -----------------------------------------------------------------


@pytest.mark.parametrize(
    "name", ["project-sunbeam-tools", "project-anything", "try-foo", "system"]
)
def test_set_on_schema_inert_names_rejected(name: str) -> None:
    user_vars = UserVars(sdks_set={name: {"channel": "latest/edge"}})
    with pytest.raises(UserVarsError, match="schema-inert"):
        build_chain(PROFILE, {}, user_vars)


def test_set_on_absent_name_rejected() -> None:
    user_vars = UserVars(sdks_set={"no-such-sdk": {"channel": "latest/edge"}})
    with pytest.raises(UserVarsError, match="no SDK named 'no-such-sdk'"):
        build_chain(PROFILE, {}, user_vars)


@pytest.mark.parametrize(
    ("name", "channel"),
    [("gh-cli", "latest/edge"), ("openchamber", "latest/stable")],
)
def test_set_on_load_bearing_sdks_warns(name: str, channel: str) -> None:
    user_vars = UserVars(sdks_set={name: {"channel": channel}})
    chain, diff, warnings = build_chain(PROFILE, {}, user_vars)
    assert len(warnings) == 1
    assert f"sdks.set.{name}" in warnings[0]
    assert "load-bearing" in warnings[0]
    entry = next(e for e in chain if e["name"] == name)
    assert entry["channel"] == channel
    assert diff.overridden == [name]


def test_set_same_channel_is_not_an_override() -> None:
    user_vars = UserVars(sdks_set={"uv": {"channel": "latest/stable"}})
    chain, diff, warnings = build_chain(PROFILE, {}, user_vars)
    assert warnings == []
    assert diff.overridden == []
    entry = next(e for e in chain if e["name"] == "uv")
    assert entry["channel"] == "latest/stable"


def test_set_on_user_added_sdk_works() -> None:
    user_vars = UserVars(
        sdks_add=[{"name": "my-sdk"}],
        sdks_set={"my-sdk": {"channel": "1/edge"}},
    )
    chain, diff, _ = build_chain(PROFILE, {}, user_vars)
    entry = next(e for e in chain if e["name"] == "my-sdk")
    assert entry["channel"] == "1/edge"
    assert diff.added == ["my-sdk"]
    assert diff.overridden == []


# --- duplicates ------------------------------------------------------------


def test_duplicate_base_name_rejected() -> None:
    user_vars = UserVars(sdks_add=[{"name": "uv"}])
    with pytest.raises(UserVarsError, match="duplicate SDK name 'uv'"):
        build_chain(PROFILE, {}, user_vars)


def test_duplicate_user_add_rejected() -> None:
    user_vars = UserVars(sdks_add=[{"name": "my-sdk"}, {"name": "my-sdk"}])
    with pytest.raises(UserVarsError, match="duplicate SDK name 'my-sdk'"):
        build_chain(PROFILE, {}, user_vars)


def test_duplicate_against_profile_extra_sdks_rejected() -> None:
    profile_vars = {"extra_sdks": [{"name": "extra-one"}]}
    user_vars = UserVars(sdks_add=[{"name": "extra-one"}])
    with pytest.raises(UserVarsError, match="duplicate SDK name 'extra-one'"):
        build_chain(PROFILE, profile_vars, user_vars)


# --- user adds and the full ChainDiff ---------------------------------------


def test_user_adds_land_before_project_sdk() -> None:
    user_vars = UserVars(
        sdks_add=[{"name": "alpha", "channel": "e"}, {"name": "beta"}]
    )
    chain, diff, warnings = build_chain(PROFILE, {}, user_vars)
    names = [entry["name"] for entry in chain]
    assert names == [
        "opencode",
        "openchamber",
        "gh-cli",
        "uv",
        "alpha",
        "beta",
        "project-sunbeam-tools",
    ]
    assert diff.added == ["alpha", "beta"]
    assert warnings == []
    # plugs/slots keys on user adds are preserved for the P4 emitter.
    user_vars = UserVars(
        sdks_add=[{"name": "gamma", "plugs": ["home"], "slots": ["src"]}]
    )
    chain, _, _ = build_chain(PROFILE, {}, user_vars)
    entry = next(e for e in chain if e["name"] == "gamma")
    assert entry == {"name": "gamma", "plugs": ["home"], "slots": ["src"]}


def test_chain_diff_reports_add_override_remove() -> None:
    profile_vars = {"extra_sdks": [{"name": "extra-one", "channel": "e"}]}
    user_vars = UserVars(
        sdks_add=[{"name": "alpha"}],
        sdks_set={"uv": {"channel": "latest/edge"}},
        sdks_remove=["extra-one"],
    )
    chain, diff, warnings = build_chain(PROFILE, profile_vars, user_vars)
    assert diff == ChainDiff(
        added=["alpha"], overridden=["uv"], removed=["extra-one"]
    )
    names = [entry["name"] for entry in chain]
    assert names == [
        "opencode",
        "openchamber",
        "gh-cli",
        "uv",
        "alpha",
        "project-sunbeam-tools",
    ]
    assert warnings == []


def test_inputs_are_not_mutated() -> None:
    profile_vars = {"extra_sdks": [{"name": "extra-one", "channel": "e"}]}
    user_vars = UserVars(sdks_set={"uv": {"channel": "latest/edge"}})
    build_chain(PROFILE, profile_vars, user_vars)
    assert profile_vars == {"extra_sdks": [{"name": "extra-one", "channel": "e"}]}
    assert BASE_CHAIN[3] == {"name": "uv", "channel": "latest/stable"}
