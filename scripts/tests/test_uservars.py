"""Tests for sunbeam_workshop.uservars (user vars layers).

Fixture trees mirror config/local/vars/... under tmp_path; the real
config/local/ tree is never created. An autouse fixture clears the
SUNBEAM_WORKSHOP_NO_USER_LAYERS kill-switch so a dev machine exporting it
(the golden/equivalence suites do, assumption A1) cannot skew results.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from sunbeam_workshop.loader import DocError, LoadedDoc, load_doc
from sunbeam_workshop.uservars import (
    KILL_SWITCH_ENV,
    UserVars,
    UserVarsError,
    discover,
    merge,
    validate_layer,
)

PROFILE = "sunbeam"
NAME = "sunbeam-x"


def write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


@pytest.fixture
def root(tmp_path: Path) -> Path:
    return tmp_path


@pytest.fixture(autouse=True)
def _clear_kill_switch(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(KILL_SWITCH_ENV, raising=False)


def slot_base(root: Path, slot: str) -> Path:
    """Suffix-less base path of a user vars layer slot."""
    return root / "config" / "local" / "vars" / slot


def make_doc(root: Path, slot: str, data: dict) -> LoadedDoc:
    """Write one layer slot as JSON and load it through the real loader."""
    base = slot_base(root, slot)
    write(base.with_suffix(".json"), json.dumps(data))
    doc = load_doc(base, f"test slot {slot}")
    assert doc is not None
    return doc


# --- discovery: scope order, absent slots, provenance -----------------------


def test_discover_scope_order_all_profile_instance(root: Path) -> None:
    all_path = write(
        slot_base(root, "all").with_suffix(".yaml"), "actions:\n  a-all: echo all\n"
    )
    profile_path = write(
        slot_base(root, "profile/sunbeam").with_suffix(".yaml"),
        "actions:\n  a-profile: echo profile\n",
    )
    instance_path = write(
        slot_base(root, "instance/sunbeam-x").with_suffix(".json"),
        '{"actions": {"a-instance": "echo instance"}}',
    )
    docs = discover(root, PROFILE, NAME)
    assert [doc.path for doc in docs] == [all_path, profile_path, instance_path]
    assert [doc.format for doc in docs] == ["yaml", "yaml", "json"]


def test_discover_no_slots_returns_empty(root: Path) -> None:
    assert discover(root, PROFILE, NAME) == []


def test_discover_absent_slots_skipped(root: Path) -> None:
    profile_path = write(
        slot_base(root, "profile/sunbeam").with_suffix(".yaml"),
        "actions:\n  a: echo\n",
    )
    docs = discover(root, PROFILE, NAME)
    assert [doc.path for doc in docs] == [profile_path]


def test_discover_provenance_preserved(root: Path) -> None:
    raw = b"actions:\n  a: echo hi\n"
    path = slot_base(root, "all").with_suffix(".yaml")
    write(path, raw.decode("utf-8"))
    (doc,) = discover(root, PROFILE, NAME)
    assert doc.path == path
    assert doc.format == "yaml"
    assert doc.digest == hashlib.sha256(raw).hexdigest()
    assert doc.data == {"actions": {"a": "echo hi"}}


def test_discover_docerror_propagates_on_coexistence(root: Path) -> None:
    json_path = write(slot_base(root, "all").with_suffix(".json"), "{}")
    yaml_path = write(slot_base(root, "all").with_suffix(".yaml"), "{}\n")
    with pytest.raises(DocError) as excinfo:
        discover(root, PROFILE, NAME)
    message = str(excinfo.value)
    assert str(json_path) in message
    assert str(yaml_path) in message


# --- discovery: the kill-switch -----------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [("1", 0), ("yes", 0), ("0", 1), ("", 1)],
    ids=["one", "truthy", "zero", "empty"],
)
def test_kill_switch(
    root: Path, monkeypatch: pytest.MonkeyPatch, value: str, expected: int
) -> None:
    write(slot_base(root, "all").with_suffix(".yaml"), "actions:\n  a: echo\n")
    monkeypatch.setenv(KILL_SWITCH_ENV, value)
    assert len(discover(root, PROFILE, NAME)) == expected


def test_kill_switch_unset_discovers(root: Path) -> None:
    write(slot_base(root, "all").with_suffix(".yaml"), "actions:\n  a: echo\n")
    assert len(discover(root, PROFILE, NAME)) == 1


# --- merge strategies ---------------------------------------------------------


def test_merge_add_concatenates_in_scope_order(root: Path) -> None:
    docs = [
        make_doc(
            root,
            "all",
            {"sdks": {"add": [{"name": "a"}, {"name": "b", "channel": "e"}]}},
        ),
        make_doc(
            root, "profile/sunbeam", {"sdks": {"add": [{"name": "c", "plugs": ["h"]}]}}
        ),
        make_doc(
            root, "instance/sunbeam-x", {"sdks": {"add": [{"name": "d", "slots": ["s"]}]}}
        ),
    ]
    merged, warnings = merge(docs)
    assert merged.sdks_add == [
        {"name": "a"},
        {"name": "b", "channel": "e"},
        {"name": "c", "plugs": ["h"]},
        {"name": "d", "slots": ["s"]},
    ]
    assert warnings == []


def test_merge_set_last_wins_by_name(root: Path) -> None:
    docs = [
        make_doc(
            root,
            "all",
            {
                "sdks": {
                    "set": {
                        "uv": {"channel": "latest/edge"},
                        "gh-cli": {"channel": "latest/stable"},
                    }
                }
            },
        ),
        make_doc(
            root,
            "instance/sunbeam-x",
            {"sdks": {"set": {"uv": {"channel": "latest/stable"}}}},
        ),
    ]
    merged, warnings = merge(docs)
    assert merged.sdks_set == {
        "uv": {"channel": "latest/stable"},
        "gh-cli": {"channel": "latest/stable"},
    }
    assert warnings == []


def test_merge_remove_unions_first_seen_order(root: Path) -> None:
    docs = [
        make_doc(root, "all", {"sdks": {"remove": ["a", "b"]}}),
        make_doc(root, "profile/sunbeam", {"sdks": {"remove": ["b", "c"]}}),
        make_doc(root, "instance/sunbeam-x", {"sdks": {"remove": ["a", "d"]}}),
    ]
    merged, _ = merge(docs)
    assert merged.sdks_remove == ["a", "b", "c", "d"]


def test_merge_actions_last_wins_with_override_warning(root: Path) -> None:
    all_path = write(
        slot_base(root, "all").with_suffix(".yaml"),
        "actions:\n  build: echo all\n  test: echo test\n",
    )
    instance_path = write(
        slot_base(root, "instance/sunbeam-x").with_suffix(".yaml"),
        "actions:\n  build: echo instance\n",
    )
    merged, warnings = merge(discover(root, PROFILE, NAME))
    assert merged.actions == {"build": "echo instance", "test": "echo test"}
    assert len(warnings) == 1
    warning = warnings[0]
    assert "action 'build'" in warning
    assert str(instance_path) in warning
    assert "overrides earlier definition from" in warning
    assert str(all_path) in warning


def test_merge_action_override_warning_tracks_latest_source(root: Path) -> None:
    docs = [
        make_doc(root, "all", {"actions": {"build": "echo all"}}),
        make_doc(root, "profile/sunbeam", {"actions": {"build": "echo profile"}}),
        make_doc(root, "instance/sunbeam-x", {"actions": {"build": "echo inst"}}),
    ]
    merged, warnings = merge(docs)
    assert merged.actions == {"build": "echo inst"}
    assert len(warnings) == 2
    all_path = str(slot_base(root, "all").with_suffix(".json"))
    profile_path = str(slot_base(root, "profile/sunbeam").with_suffix(".json"))
    instance_path = str(slot_base(root, "instance/sunbeam-x").with_suffix(".json"))
    assert all_path in warnings[0] and profile_path in warnings[0]
    assert profile_path in warnings[1] and instance_path in warnings[1]


def test_merge_actions_no_override_no_warning(root: Path) -> None:
    docs = [
        make_doc(root, "all", {"actions": {"build": "echo all"}}),
        make_doc(root, "instance/sunbeam-x", {"actions": {"test": "echo test"}}),
    ]
    merged, warnings = merge(docs)
    assert merged.actions == {"build": "echo all", "test": "echo test"}
    assert warnings == []


def test_merge_empty_docs_yields_empty_uservars() -> None:
    merged, warnings = merge([])
    assert merged == UserVars()
    assert warnings == []


# --- strict schema validation -------------------------------------------------


def test_validate_layer_accepts_full_valid_doc(root: Path) -> None:
    doc = make_doc(
        root,
        "all",
        {
            "sdks": {
                "add": [
                    {"name": "foo"},
                    {
                        "name": "bar",
                        "channel": "latest/edge",
                        "plugs": ["home", "network"],
                        "slots": ["src"],
                    },
                ],
                "set": {"uv": {"channel": "latest/stable"}},
                "remove": ["orange-dev-tools"],
            },
            "actions": {"build": "echo build\n", "test-unit": "pytest -q\n"},
        },
    )
    assert validate_layer(doc) is None


def test_validate_layer_null_optional_keys_count_as_absent(root: Path) -> None:
    base = slot_base(root, "all")
    write(
        base.with_suffix(".yaml"),
        "sdks:\n  add:\n    - name: foo\n      channel: ~\n      plugs: ~\n",
    )
    doc = load_doc(base, "test slot all")
    assert doc is not None
    assert validate_layer(doc) is None
    merged, _ = merge([doc])
    assert merged.sdks_add == [{"name": "foo"}]


STRICT_REJECTS: list[tuple[str, list[str]]] = [
    ("bogus: 1\n", ["unknown top-level key 'bogus'"]),
    ("sdks: {bogus: 1}\n", ["unknown sdks key 'bogus'"]),
    ('sdks: "nope"\n', ["sdks must be a dict"]),
    ('actions: "nope"\n', ["actions must be a dict"]),
    ('sdks: {add: "nope"}\n', ["sdks.add must be a list"]),
    ('sdks: {set: "nope"}\n', ["sdks.set must be a dict"]),
    ('sdks: {remove: "nope"}\n', ["sdks.remove must be a list"]),
    ('sdks: {add: ["nope"]}\n', ["sdks.add[0] must be a dict"]),
    ("sdks: {add: [{channel: latest/edge}]}\n", ["sdks.add[0].name is required"]),
    ("sdks: {add: [{name: 42}]}\n", ["sdks.add[0].name must be a non-empty string"]),
    ("sdks: {add: [{name: ''}]}\n", ["sdks.add[0].name must be a non-empty string"]),
    (
        "sdks: {add: [{name: foo, bogus: 1}]}\n",
        ["sdks.add[0]", "unknown key 'bogus'"],
    ),
    (
        "sdks: {add: [{name: foo, channel: 42}]}\n",
        ["sdks.add[0].channel must be a string"],
    ),
    (
        'sdks: {add: [{name: foo, plugs: "nope"}]}\n',
        ["sdks.add[0].plugs must be a list of strings"],
    ),
    (
        "sdks: {add: [{name: foo, plugs: [a, 1]}]}\n",
        ["sdks.add[0].plugs must be a list of strings"],
    ),
    (
        "sdks: {add: [{name: foo, slots: [1]}]}\n",
        ["sdks.add[0].slots must be a list of strings"],
    ),
    (
        "sdks: {set: {uv: {risk: latest/edge}}}\n",
        ["sdks.set.uv", "unknown key 'risk'"],
    ),
    ("sdks: {set: {uv: {channel: 42}}}\n", ["sdks.set.uv.channel must be a string"]),
    ("sdks: {set: {uv: {}}}\n", ["sdks.set.uv.channel is required"]),
    ('sdks: {set: {uv: "nope"}}\n', ["sdks.set.uv must be a dict"]),
    ("sdks: {set: {1: {channel: x}}}\n", ["sdks.set", "name must be a string"]),
    ("sdks: {remove: [a, 1]}\n", ["sdks.remove[1] must be a string"]),
    ('actions: {Foo: "echo hi"}\n', ["actions.Foo", "invalid action name"]),
    ("actions: {my-act: 42}\n", ["actions.my-act must be a string"]),
    ('actions: {1: "echo hi"}\n', ["invalid action name"]),
]


@pytest.mark.parametrize(
    ("content", "fragments"),
    STRICT_REJECTS,
    ids=[f"reject-{i}" for i in range(len(STRICT_REJECTS))],
)
def test_validate_layer_strict_rejects(
    root: Path, content: str, fragments: list[str]
) -> None:
    base = slot_base(root, "all")
    path = write(base.with_suffix(".yaml"), content)
    doc = load_doc(base, "test slot all")
    assert doc is not None
    with pytest.raises(UserVarsError) as excinfo:
        validate_layer(doc)
    message = str(excinfo.value)
    assert str(path) in message
    for fragment in fragments:
        assert fragment in message


def test_validate_layer_reject_names_json_path(root: Path) -> None:
    base = slot_base(root, "all")
    path = write(base.with_suffix(".json"), '{"sdks": {"bogus": 1}}')
    doc = load_doc(base, "test slot all")
    assert doc is not None
    with pytest.raises(UserVarsError) as excinfo:
        validate_layer(doc)
    message = str(excinfo.value)
    assert str(path) in message
    assert "unknown sdks key 'bogus'" in message


def test_merge_validates_every_doc_before_merging(root: Path) -> None:
    # A valid all-layer does not mask an invalid instance layer.
    write(slot_base(root, "all").with_suffix(".yaml"), "actions:\n  a: echo\n")
    bad_path = write(
        slot_base(root, "instance/sunbeam-x").with_suffix(".yaml"), "bogus: 1\n"
    )
    with pytest.raises(UserVarsError) as excinfo:
        merge(discover(root, PROFILE, NAME))
    message = str(excinfo.value)
    assert str(bad_path) in message
    assert "unknown top-level key 'bogus'" in message
