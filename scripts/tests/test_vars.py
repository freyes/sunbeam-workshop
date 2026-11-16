"""Tests for sunbeam_workshop.config and sunbeam_workshop.vars.

All tests run against a fixture ROOT built under tmp_path - never the real
profiles/ tree - and monkeypatch USER where identity matters.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from sunbeam_workshop.__main__ import main
from sunbeam_workshop.config import deep_merge, load_config
from sunbeam_workshop.uservars import KILL_SWITCH_ENV
from sunbeam_workshop.vars import (
    InstanceCollisionError,
    InvalidNameError,
    UnknownProfileError,
    build_vars,
    build_vars_full,
    current_user,
    list_profiles,
    resolve_name,
)

PROFILES = ("charmed", "packaging", "sunbeam")


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture
def root(tmp_path: Path) -> Path:
    for profile in PROFILES:
        (tmp_path / "profiles" / profile).mkdir(parents=True)
    (tmp_path / "config").mkdir()
    return tmp_path


# --- config layer merge ----------------------------------------------------


def test_merge_precedence(root: Path) -> None:
    write_json(
        root / "config" / "config.json",
        {"a": {"x": 1, "y": 1}, "lst": [1], "scalar": "base", "only_base": True},
    )
    write_json(
        root / "config" / "local.json",
        {"a": {"y": 2}, "lst": [2, 3], "scalar": "local"},
    )
    write_json(
        root / "config" / "alice" / "config.json",
        {"a": {"z": 3}, "scalar": "user"},
    )
    merged = load_config(root, "alice")
    assert merged == {
        "a": {"x": 1, "y": 2, "z": 3},  # dicts merge recursively, later wins
        "lst": [2, 3],  # lists replace, they do not concatenate
        "scalar": "user",  # scalars replace, later layer wins
        "only_base": True,
    }


def test_missing_layers_skipped(root: Path) -> None:
    assert load_config(root, "alice") == {}
    write_json(root / "config" / "local.json", {"k": "v"})
    assert load_config(root, "alice") == {"k": "v"}
    assert load_config(root, "bob") == {"k": "v"}  # no per-user layer for bob


def test_deep_merge_overlay_replaces_non_dict() -> None:
    assert deep_merge({"a": [1, 2]}, {"a": [3]}) == {"a": [3]}
    assert deep_merge({"a": {"b": 1}}, {"a": "scalar"}) == {"a": "scalar"}
    assert deep_merge({"a": "scalar"}, {"a": {"b": 1}}) == {"a": {"b": 1}}


# --- name resolution -------------------------------------------------------


def test_exact_match_beats_prefix(root: Path) -> None:
    (root / "profiles" / "packaging-foo").mkdir()
    resolution = resolve_name(root, "packaging-foo")
    assert (resolution.profile, resolution.suffix) == ("packaging-foo", "")
    assert resolution.shadow_warning is False


def test_prefix_resolution_packaging_foo(root: Path) -> None:
    resolution = resolve_name(root, "packaging-foo")
    assert (resolution.profile, resolution.suffix) == ("packaging", "foo")


def test_multi_segment_suffix(root: Path) -> None:
    resolution = resolve_name(root, "packaging-foo-bar")
    assert (resolution.profile, resolution.suffix) == ("packaging", "foo-bar")


def test_longest_prefix_wins(root: Path) -> None:
    (root / "profiles" / "packaging-foo").mkdir()
    resolution = resolve_name(root, "packaging-foo-bar")
    assert (resolution.profile, resolution.suffix) == ("packaging-foo", "bar")


def test_unknown_prefix_error_lists_profiles(root: Path) -> None:
    with pytest.raises(UnknownProfileError) as excinfo:
        resolve_name(root, "unknownprofile")
    message = str(excinfo.value)
    for profile in PROFILES:
        assert profile in message


def test_underscore_dirs_are_not_profiles(root: Path) -> None:
    # A profiles/_junk-style dir (shared partials) is never a valid profile.
    (root / "profiles" / "_junk").mkdir()
    assert list_profiles(root) == sorted(PROFILES)
    with pytest.raises(UnknownProfileError) as excinfo:
        resolve_name(root, "unknownprofile")
    message = str(excinfo.value)
    assert "_junk" not in message
    for profile in PROFILES:
        assert profile in message


@pytest.mark.parametrize(
    "name",
    [
        "Packaging",  # uppercase
        "9packaging",  # leading digit
        "a" * 41,  # > 40 characters
        "packaging--foo",  # double hyphen
    ],
)
def test_name_rules_rejection(root: Path, name: str) -> None:
    with pytest.raises(InvalidNameError):
        resolve_name(root, name)


def test_workshop_dir_collision(root: Path) -> None:
    (root / ".workshop" / "packaging-foo").mkdir(parents=True)
    with pytest.raises(InstanceCollisionError):
        resolve_name(root, "packaging-foo")


def test_shadow_warning(root: Path) -> None:
    # Both profiles/packaging-foo/ and .workshop/packaging-foo/ exist: the
    # profile shadows the existing instance (D-13) -> warn, do not reject.
    (root / "profiles" / "packaging-foo").mkdir()
    (root / ".workshop" / "packaging-foo").mkdir(parents=True)
    doc = build_vars(root, "packaging-foo", user="alice")
    assert doc["profile"] == "packaging-foo"
    assert doc["suffix"] == ""
    assert doc["shadow_warning"] is True


# --- user identity -----------------------------------------------------------


def test_current_user_strips_only_trailing_suffix(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("USER", "alice@canonical.com")
    assert current_user() == "alice"
    # A non-trailing '@canonical.com' is left untouched (docstring: suffix).
    monkeypatch.setenv("USER", "alice@canonical.com.example.com")
    assert current_user() == "alice@canonical.com.example.com"


# --- merged vars doc -------------------------------------------------------


def test_missing_vars_json_tolerated_as_empty(root: Path) -> None:
    doc = build_vars(root, "packaging-foo", user="alice")
    assert doc["profile_vars"] == {}


def test_profile_vars_loaded(root: Path) -> None:
    write_json(root / "profiles" / "packaging" / "vars.json", {"base": "ubuntu@26.04"})
    doc = build_vars(root, "packaging-foo", user="alice")
    assert doc["profile_vars"] == {"base": "ubuntu@26.04"}


def test_vars_doc_shape(root: Path) -> None:
    write_json(
        root / "config" / "alice" / "config.json",
        {"github_handle": "alicegh", "email": "alice@example.com"},
    )
    doc = build_vars(root, "packaging-foo", user="alice")
    assert doc["workshop_name"] == "packaging-foo"
    assert doc["profile"] == "packaging"
    assert doc["suffix"] == "foo"
    assert doc["shadow_warning"] is False
    assert doc["user"] == {
        "name": "alice",
        "github_handle": "alicegh",
        "email": "alice@example.com",
    }
    assert doc["config"]["github_handle"] == "alicegh"


# --- CLI -------------------------------------------------------------------


def test_cli_vars_emits_json(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    write_json(
        root / "config" / "alice" / "config.json",
        {"github_handle": "alicegh", "email": "alice@example.com"},
    )
    monkeypatch.setenv("USER", "alice")
    (root / "scripts").mkdir()
    monkeypatch.chdir(root / "scripts")  # root discovered by walking up
    assert main(["vars", "packaging-foo"]) == 0
    doc = json.loads(capsys.readouterr().out)
    assert doc["workshop_name"] == "packaging-foo"
    assert doc["profile"] == "packaging"
    assert doc["suffix"] == "foo"
    assert doc["profile_vars"] == {}
    assert doc["user"]["github_handle"] == "alicegh"


def test_cli_strips_canonical_suffix(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    write_json(root / "config" / "alice" / "config.json", {"github_handle": "alicegh"})
    monkeypatch.setenv("USER", "alice@canonical.com")
    monkeypatch.chdir(root)
    assert main(["vars", "packaging"]) == 0
    doc = json.loads(capsys.readouterr().out)
    assert doc["user"]["name"] == "alice"
    assert doc["config"]["github_handle"] == "alicegh"


def test_cli_invalid_name_exit_4(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.chdir(root)
    assert main(["vars", "Bogus-Name"]) == 4
    assert "invalid workshop name" in capsys.readouterr().err


def test_cli_unknown_profile_exit_3_lists_profiles(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.chdir(root)
    assert main(["vars", "unknownprofile"]) == 3
    err = capsys.readouterr().err
    for profile in PROFILES:
        assert profile in err


def test_cli_collision_exit_5(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    (root / ".workshop" / "packaging-foo").mkdir(parents=True)
    monkeypatch.chdir(root)
    assert main(["vars", "packaging-foo"]) == 5
    assert "already exists" in capsys.readouterr().err


# --- build_vars_full: chain, actions, provenance -------------------------------


@pytest.fixture(autouse=True)
def _clear_user_layers_kill_switch(monkeypatch: pytest.MonkeyPatch) -> None:
    # The golden/equivalence suites export the kill-switch (assumption A1);
    # a dev machine's environment must not skew these tests.
    monkeypatch.delenv(KILL_SWITCH_ENV, raising=False)


def write_user_layer(root: Path, slot: str, data: dict) -> Path:
    """Write one config/local/vars/<slot>.json layer under the fixture root."""
    path = root / "config" / "local" / "vars" / f"{slot}.json"
    write_json(path, data)
    return path


def test_build_vars_full_doc_gains_sdks_actions_layers(root: Path) -> None:
    write_json(
        root / "profiles" / "packaging" / "vars.json",
        {"extra_sdks": [{"name": "orange-dev-tools", "channel": "latest/edge"}]},
    )
    result = build_vars_full(root, "packaging-foo", user="alice")
    doc = result.doc
    assert [entry["name"] for entry in doc["sdks"]] == [
        "opencode",
        "openchamber",
        "gh-cli",
        "uv",
        "orange-dev-tools",
        "project-packaging-tools",
    ]
    assert doc["actions"] == {}
    assert len(doc["_layers"]) == 1
    (layer,) = doc["_layers"]
    assert layer["kind"] == "profile"
    assert layer["path"] == str(root / "profiles" / "packaging" / "vars.json")
    assert layer["format"] == "json"
    assert len(layer["digest"]) == 64
    # No user layers: nothing applied, empty diff, no warnings.
    assert result.layers_applied == 0
    assert (result.chain_diff.added, result.chain_diff.removed) == ([], [])
    assert result.chain_diff.overridden == []
    assert result.actions_added == 0
    assert result.warnings == []


def test_build_vars_legacy_doc_gains_nothing(root: Path) -> None:
    write_user_layer(root, "all", {"actions": {"a": "echo a"}})
    doc = build_vars(root, "packaging-foo", user="alice")
    assert "sdks" not in doc
    assert "actions" not in doc
    assert "_layers" not in doc
    assert set(doc) == {
        "workshop_name",
        "profile",
        "suffix",
        "shadow_warning",
        "profile_vars",
        "config",
        "user",
    }


def test_build_vars_full_layers_empty_when_no_slots(root: Path) -> None:
    # No profile vars slot and no user layers: provenance is empty.
    result = build_vars_full(root, "packaging-foo", user="alice")
    assert result.doc["_layers"] == []
    assert result.layers_applied == 0
    assert result.doc["actions"] == {}


def test_build_vars_full_layers_populated_in_scope_order(root: Path) -> None:
    write_json(root / "profiles" / "packaging" / "vars.json", {"k": "v"})
    all_path = write_user_layer(root, "all", {"actions": {"a": "echo all"}})
    instance_path = write_user_layer(
        root, "instance/packaging-foo", {"actions": {"b": "echo inst"}}
    )
    result = build_vars_full(root, "packaging-foo", user="alice")
    layers = result.doc["_layers"]
    assert [layer["kind"] for layer in layers] == ["profile", "user", "user"]
    assert [layer["path"] for layer in layers] == [
        str(root / "profiles" / "packaging" / "vars.json"),
        str(all_path),
        str(instance_path),
    ]
    assert result.layers_applied == 2
    assert result.doc["actions"] == {"a": "echo all", "b": "echo inst"}
    assert result.actions_added == 2


def test_build_vars_full_actions_merge_and_override_warning(root: Path) -> None:
    write_json(
        root / "profiles" / "packaging" / "vars.json",
        {"actions": {"build": "echo profile", "profile-only": "echo p"}},
    )
    write_user_layer(
        root,
        "instance/packaging-foo",
        {"actions": {"build": "echo user", "test": "echo t"}},
    )
    result = build_vars_full(root, "packaging-foo", user="alice")
    assert result.doc["actions"] == {
        "build": "echo user",  # user layer wins over the profile action
        "profile-only": "echo p",
        "test": "echo t",
    }
    assert result.actions_added == 1  # only 'test' is new
    assert result.warnings == [
        "action 'build' from user layer overrides profile action"
    ]


def test_build_vars_full_chain_summary_fields(root: Path) -> None:
    write_user_layer(
        root,
        "profile/packaging",
        {
            "sdks": {
                "add": [{"name": "extra-sdk"}],
                "set": {"uv": {"channel": "latest/edge"}},
            },
        },
    )
    result = build_vars_full(root, "packaging-foo", user="alice")
    assert result.chain_diff.added == ["extra-sdk"]
    assert result.chain_diff.overridden == ["uv"]
    assert result.chain_diff.removed == []
    assert result.layers_applied == 1
    names = [entry["name"] for entry in result.doc["sdks"]]
    assert names == [
        "opencode",
        "openchamber",
        "gh-cli",
        "uv",
        "extra-sdk",
        "project-packaging-tools",
    ]


def test_cli_vars_stdout_stays_pure_json_with_summary_on_stderr(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    write_user_layer(
        root,
        "profile/packaging",
        {
            "sdks": {
                "add": [{"name": "extra-sdk"}],
                "set": {"uv": {"channel": "latest/edge"}},
            },
            "actions": {"hello": "echo hi"},
        },
    )
    monkeypatch.setenv("USER", "alice")
    monkeypatch.chdir(root)
    assert main(["vars", "packaging"]) == 0
    captured = capsys.readouterr()
    doc = json.loads(captured.out)  # stdout parses as pure JSON
    assert doc["workshop_name"] == "packaging"
    assert [entry["name"] for entry in doc["sdks"]][-2:] == [
        "extra-sdk",
        "project-packaging-tools",
    ]
    assert doc["actions"] == {"hello": "echo hi"}
    assert (
        "layers: 1 applied; sdks +1 ~1 -0; actions +1" in captured.err
    )


def test_cli_vars_no_layers_summary_is_zeroed(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("USER", "alice")
    monkeypatch.chdir(root)
    assert main(["vars", "packaging"]) == 0
    captured = capsys.readouterr()
    json.loads(captured.out)
    assert (
        "layers: 0 applied; sdks +0 ~0 -0; actions +0" in captured.err
    )


def test_cli_vars_warnings_on_stderr_not_stdout(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    write_user_layer(
        root,
        "all",
        {"sdks": {"set": {"gh-cli": {"channel": "latest/edge"}}}},
    )
    monkeypatch.setenv("USER", "alice")
    monkeypatch.chdir(root)
    assert main(["vars", "packaging"]) == 0
    captured = capsys.readouterr()
    json.loads(captured.out)  # stdout stays pure JSON
    assert "warning: sdks.set.gh-cli" in captured.err
    assert "load-bearing" in captured.err
    assert "~1" in captured.err
