"""Tests for sunbeam_workshop.layers (the `layers` visibility report).

Fixture roots mirror test_vars.py (profiles/<p>/ dirs + a config/ dir under
tmp_path); user layers, fragments, user SDKs, and the persisted vars doc all
live under the fixture root - the real config/local/, .workshop/, and .state/
trees are never touched. The state dir is redirected with
SUNBEAM_WORKSHOP_STATE_DIR (the lib-common.sh override layers.py honors).
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from sunbeam_workshop.__main__ import main
from sunbeam_workshop.layers import STATE_DIR_ENV, build_report
from sunbeam_workshop.uservars import KILL_SWITCH_ENV

PROFILES = ("charmed", "packaging", "sunbeam")


def write_json(path: Path, data: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def write_text(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def digest_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@pytest.fixture
def root(tmp_path: Path) -> Path:
    for profile in PROFILES:
        (tmp_path / "profiles" / profile).mkdir(parents=True)
    (tmp_path / "config").mkdir()
    return tmp_path


@pytest.fixture(autouse=True)
def _clear_env_overrides(monkeypatch: pytest.MonkeyPatch) -> None:
    # Dev-machine exports (the golden/equivalence suites set the kill-switch,
    # assumption A1) must not skew these tests.
    monkeypatch.delenv(KILL_SWITCH_ENV, raising=False)
    monkeypatch.delenv(STATE_DIR_ENV, raising=False)


def write_user_layer(root: Path, slot: str, content: str, fmt: str = "json") -> Path:
    """Write one config/local/vars/<slot>.<fmt> layer under the fixture root."""
    return write_text(root / "config" / "local" / "vars" / f"{slot}.{fmt}", content)


def write_state_doc(
    monkeypatch: pytest.MonkeyPatch, root: Path, name: str, layers: list[dict]
) -> Path:
    """Fake .state/<name>.vars.json in a redirected state dir; returns its path."""
    state_dir = root / "fixture-state"
    state_dir.mkdir()
    monkeypatch.setenv(STATE_DIR_ENV, str(state_dir))
    path = state_dir / f"{name}.vars.json"
    path.write_text(json.dumps({"_layers": layers}), encoding="utf-8")
    return path


def current_entry(kind: str, path: Path, fmt: str) -> dict[str, str]:
    """The _layers entry the current tree would record for one doc (A3)."""
    return {
        "kind": kind,
        "path": str(path),
        "format": fmt,
        "digest": digest_of(path),
    }


# --- no-layers report -------------------------------------------------------


def test_report_no_layers(root: Path) -> None:
    report = build_report(root, "packaging-foo")
    assert "layers report for workshop 'packaging-foo' (profile: packaging, suffix: foo)" in report
    assert f"kill-switch {KILL_SWITCH_ENV}: inactive" in report
    assert "(no user layers applied)" in report
    assert "(no changes; the effective chain is the default)" in report
    assert "(none defined)" in report  # actions
    assert "(none discovered under config/local/hooks/)" in report
    assert "(none discovered)" in report  # user SDKs
    # A missing state doc is reported, never an error.
    assert "no persisted vars doc; nothing to compare" in report
    assert "just setup packaging-foo" in report


def test_report_kill_switch_active_shown_and_layers_ignored(
    root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_user_layer(root, "all", '{"actions": {"a": "echo a"}}')
    monkeypatch.setenv(KILL_SWITCH_ENV, "1")
    report = build_report(root, "packaging-foo")
    assert f"kill-switch {KILL_SWITCH_ENV}: ACTIVE (user layers ignored)" in report
    assert "(no user layers applied)" in report
    assert "echo a" not in report


# --- with-layers report -------------------------------------------------------


def test_report_with_layers_lists_paths_formats_digests(root: Path) -> None:
    all_path = write_user_layer(root, "all", "actions:\n  a-all: echo all\n", fmt="yaml")
    inst_path = write_user_layer(
        root,
        "instance/packaging-foo",
        '{"actions": {"a-inst": "echo inst"}}',
    )
    report = build_report(root, "packaging-foo")
    assert f"- config/local/vars/all.yaml [yaml, sha256:{digest_of(all_path)[:12]}]" in report
    assert (
        f"- config/local/vars/instance/packaging-foo.json "
        f"[json, sha256:{digest_of(inst_path)[:12]}]" in report
    )


def test_report_chain_diff_marks_added_overridden_removed(root: Path) -> None:
    write_json(
        root / "profiles" / "packaging" / "vars.json",
        {"extra_sdks": [{"name": "orange-dev-tools", "channel": "latest/edge"}]},
    )
    write_user_layer(
        root,
        "profile/packaging",
        '{"sdks": {"add": [{"name": "extra-sdk"}], '
        '"set": {"uv": {"channel": "latest/edge"}}, '
        '"remove": ["orange-dev-tools"]}}',
    )
    report = build_report(root, "packaging-foo")
    assert "added: extra-sdk" in report
    assert "overridden: uv" in report
    assert "removed: orange-dev-tools" in report


def test_report_actions_named_with_source_layer(root: Path) -> None:
    write_json(
        root / "profiles" / "packaging" / "vars.json",
        {"actions": {"build": "echo profile"}},
    )
    write_user_layer(root, "all", '{"actions": {"test": "echo test"}}')
    report = build_report(root, "packaging-foo")
    assert "- build (profile vars (profiles/packaging/vars.json))" in report
    assert "- test (user layer (config/local/vars/all.json))" in report
    # Bodies are not part of the report: names and sources only.
    assert "echo profile" not in report
    assert "echo test" not in report


def test_report_warns_on_loadbearing_set_and_action_override(root: Path) -> None:
    write_json(
        root / "profiles" / "packaging" / "vars.json",
        {"actions": {"build": "echo profile"}},
    )
    write_user_layer(
        root,
        "instance/packaging-foo",
        '{"sdks": {"set": {"gh-cli": {"channel": "latest/edge"}}}, '
        '"actions": {"build": "echo user"}}',
    )
    report = build_report(root, "packaging-foo")
    assert "== Warnings" in report
    assert "sdks.set.gh-cli" in report
    assert "action 'build' from user layer overrides profile action" in report
    # The override won: the source is the user layer.
    assert "- build (user layer (config/local/vars/instance/packaging-foo.json))" in report


# --- fragments and user SDKs ---------------------------------------------------


def test_report_discovers_fragments_in_run_order(root: Path) -> None:
    write_text(
        root / "config" / "local" / "hooks" / "all" / "setup-project.d" / "10-a.sh",
        "# fragment\n",
    )
    write_text(
        root / "config" / "local" / "hooks" / "packaging" / "check-health.d" / "20-b.sh",
        "# fragment\n",
    )
    write_text(
        root / "config" / "local" / "hooks" / "packaging-foo" / "setup-project.d" / "30-c.sh",
        "# fragment\n",
    )
    report = build_report(root, "packaging-foo")
    all_fragment = "config/local/hooks/all/setup-project.d/10-a.sh"
    profile_fragment = "config/local/hooks/packaging/check-health.d/20-b.sh"
    instance_fragment = "config/local/hooks/packaging-foo/setup-project.d/30-c.sh"
    assert all_fragment in report
    assert profile_fragment in report
    assert instance_fragment in report
    # Run order: scope all -> profile -> instance.
    assert (
        report.index(all_fragment)
        < report.index(profile_fragment)
        < report.index(instance_fragment)
    )


def test_report_discovers_user_sdks(root: Path) -> None:
    (root / ".workshop" / "packaging-foo-user-tools").mkdir(parents=True)
    write_user_layer(root, "all", '{"sdks": {"add": [{"name": "project-ci-tools"}]}}')
    report = build_report(root, "packaging-foo")
    assert "- .workshop/packaging-foo-user-tools/ (user-owned in-project SDK)" in report
    assert "- project-ci-tools (sdks.add entry from user layers)" in report


def test_report_unsuffixed_instance_dedupes_shared_scope_dir(root: Path) -> None:
    # For an unsuffixed instance the profile and instance hook scopes are the
    # same directory; fragments there are listed once, not twice.
    write_text(
        root / "config" / "local" / "hooks" / "packaging" / "setup-project.d" / "10-a.sh",
        "# fragment\n",
    )
    report = build_report(root, "packaging")
    assert report.count("config/local/hooks/packaging/setup-project.d/10-a.sh") == 1


# --- drift vs the persisted vars doc ------------------------------------------


def test_report_drift_names_changed_layer(
    root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    layer_path = write_user_layer(root, "all", '{"actions": {"a": "echo a"}}')
    stale = current_entry("user", layer_path, "json")
    stale["digest"] = "0" * 64  # recorded before the layer was edited
    write_state_doc(monkeypatch, root, "packaging-foo", [stale])
    report = build_report(root, "packaging-foo")
    assert "DRIFT - 1 layer(s) differ" in report
    assert "config/local/vars/all.json: content changed" in report
    assert "Re-run `just setup packaging-foo`" in report


def test_report_drift_names_added_and_dropped_layers(
    root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_user_layer(root, "all", '{"actions": {"a": "echo a"}}')
    gone = {
        "kind": "user",
        "path": str(root / "config" / "local" / "vars" / "profile" / "packaging.json"),
        "format": "json",
        "digest": "f" * 64,
    }
    write_state_doc(monkeypatch, root, "packaging-foo", [gone])
    report = build_report(root, "packaging-foo")
    assert "DRIFT - 2 layer(s) differ" in report
    assert "profile/packaging.json: recorded but no longer applied" in report
    assert "config/local/vars/all.json: applied but not recorded" in report


def test_report_in_sync_when_digests_match(
    root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    profile_path = write_json(
        root / "profiles" / "packaging" / "vars.json", {"base": "ubuntu@26.04"}
    )
    layer_path = write_user_layer(root, "all", '{"actions": {"a": "echo a"}}')
    write_state_doc(
        monkeypatch,
        root,
        "packaging-foo",
        [
            current_entry("profile", profile_path, "json"),
            current_entry("user", layer_path, "json"),
        ],
    )
    report = build_report(root, "packaging-foo")
    assert "in sync (2 layer digest(s) match)" in report
    assert "DRIFT" not in report


def test_report_state_doc_without_layers_provenance(
    root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state_dir = root / "fixture-state"
    state_dir.mkdir()
    monkeypatch.setenv(STATE_DIR_ENV, str(state_dir))
    (state_dir / "packaging-foo.vars.json").write_text(
        json.dumps({"workshop_name": "packaging-foo"}), encoding="utf-8"
    )
    report = build_report(root, "packaging-foo")
    assert "no _layers provenance recorded" in report
    assert "DRIFT" not in report


# --- CLI ---------------------------------------------------------------------


def test_cli_layers_exit_0_with_report_on_stdout(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    write_user_layer(root, "all", '{"actions": {"hello": "echo hi"}}')
    monkeypatch.chdir(root)
    assert main(["layers", "packaging-foo"]) == 0
    captured = capsys.readouterr()
    assert "layers report for workshop 'packaging-foo'" in captured.out
    assert "config/local/vars/all.json" in captured.out
    assert "- hello (user layer" in captured.out
    assert captured.err == ""


def test_cli_layers_invalid_name_exit_4(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.chdir(root)
    assert main(["layers", "Bogus-Name"]) == 4
    assert "invalid workshop name" in capsys.readouterr().err


def test_cli_layers_unknown_profile_exit_3(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.chdir(root)
    assert main(["layers", "unknownprofile"]) == 3
    assert "unknown profile" in capsys.readouterr().err


def test_cli_layers_schema_violation_exit_2(
    root: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    write_user_layer(root, "all", '{"bogus": 1}')
    monkeypatch.chdir(root)
    assert main(["layers", "packaging-foo"]) == 2
    err = capsys.readouterr().err
    assert "unknown top-level key 'bogus'" in err
