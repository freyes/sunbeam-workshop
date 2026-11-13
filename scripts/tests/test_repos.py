"""Tests for sunbeam_workshop.repos.

All tests run against LOCAL git fixtures: bare remotes are initialised under
tmp_path (no network), and ``gh`` / ``git-review`` are stubbed via PATH
shims so the github and opendev code paths run offline. The fixture ROOT
mirrors the repo layout (profiles/, config/repos/) and the clone root is
redirected with SUNBEAM_WORKSHOP_GIT_ROOT.
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from sunbeam_workshop import repos
from sunbeam_workshop.__main__ import main

PROFILES = ("charmed", "packaging", "sunbeam")

GH_SHIM = """#!/bin/bash
set -e
if [ "$1" = "repo" ] && [ "$2" = "clone" ]; then
    shift 2
    exec git clone "$@"
fi
echo "gh shim: unsupported invocation: $*" >&2
exit 1
"""

# Invoked by git as `git-review -s` for `git review -s`.
GIT_REVIEW_SHIM = """#!/bin/bash
set -e
if [ "$1" = "-s" ]; then
    host="$(git config -f .gitreview gerrit.host 2>/dev/null || true)"
    host="${host:-review.opendev.org}"
    project="$(git config -f .gitreview gerrit.project 2>/dev/null || true)"
    if [ -z "$project" ]; then
        project="$(basename "$(git remote get-url origin)" .git)"
    fi
    user="$(git config gitreview.username || true)"
    if [ -z "$user" ]; then
        echo "git-review shim: gitreview.username is not set" >&2
        exit 1
    fi
    git remote remove gerrit 2>/dev/null || true
    git remote add gerrit "ssh://$user@$host:29418/$project.git"
    exit 0
fi
echo "git-review shim: unsupported invocation: $*" >&2
exit 1
"""

GITREVIEW_FILE = (
    "[gerrit]\n"
    "host=review.opendev.org\n"
    "port=29418\n"
    "project=openstack/sunbeam-charms\n"
)


def git(*args: str) -> str:
    proc = subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    )
    return proc.stdout.strip()


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture
def root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    root = tmp_path / "repo"
    for profile in PROFILES:
        (root / "profiles" / profile).mkdir(parents=True)
    (root / "config" / "repos").mkdir(parents=True)
    (root / "git").mkdir()
    monkeypatch.setenv("USER", "alice")
    monkeypatch.setenv("SUNBEAM_WORKSHOP_GIT_ROOT", str(root / "git"))
    monkeypatch.setenv("GIT_AUTHOR_NAME", "Test")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "test@example.com")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "Test")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "test@example.com")
    monkeypatch.chdir(root)
    return root


@pytest.fixture
def shims(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    bindir = tmp_path / "shim-bin"
    bindir.mkdir()
    for name, body in (("gh", GH_SHIM), ("git-review", GIT_REVIEW_SHIM)):
        path = bindir / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")
    return bindir


def make_remote(root: Path, name: str, files: dict[str, str] | None = None) -> tuple[Path, Path]:
    """Bare remote + its seed work clone under root/remotes/."""
    remotes = root / "remotes"
    remotes.mkdir(exist_ok=True)
    bare = remotes / f"{name}.git"
    work = remotes / f"{name}-work"
    git("init", "--bare", "--initial-branch=main", str(bare))
    git("init", "--initial-branch=main", str(work))
    git("-C", str(work), "remote", "add", "origin", str(bare))
    for rel, content in (files or {"README.md": f"# {name}\n"}).items():
        path = work / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    git("-C", str(work), "add", ".")
    git("-C", str(work), "commit", "-m", "seed")
    git("-C", str(work), "push", "-u", "origin", "main")
    return bare, work


def advance_remote(work: Path, rel: str, content: str) -> str:
    path = work / rel
    path.write_text(content, encoding="utf-8")
    git("-C", str(work), "add", ".")
    git("-C", str(work), "commit", "-m", "advance")
    git("-C", str(work), "push")
    return git("-C", str(work), "rev-parse", "HEAD")


def write_repo_config(
    root: Path, profile: str, core: list[dict], supporting: list[dict] | None = None
) -> None:
    write_json(
        root / "config" / "repos" / f"{profile}.json",
        {"core_repos": core, "supporting_repos": supporting or []},
    )


def read_summary(capsys: pytest.CaptureFixture[str]) -> dict:
    return json.loads(capsys.readouterr().out)


# --- list --------------------------------------------------------------------


def test_list_prints_config_entries(
    root: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    entries = [
        {
            "name": "keystone",
            "forge": "launchpad",
            "url": "https://git.launchpad.net/ubuntu/+source/keystone",
        }
    ]
    write_repo_config(root, "packaging", core=entries)
    assert main(["repos", "list", "packaging"]) == 0
    doc = read_summary(capsys)
    assert doc["workshop"] == "packaging"
    assert doc["profile"] == "packaging"
    assert doc["core_repos"] == entries
    assert doc["supporting_repos"] == []


def test_list_unknown_forge_rejected(
    root: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write_repo_config(
        root,
        "sunbeam",
        core=[{"name": "bad", "forge": "gitlab", "url": "https://example.com/bad"}],
    )
    assert main(["repos", "list", "sunbeam"]) == 2
    err = capsys.readouterr().err
    assert "unknown forge 'gitlab'" in err
    assert "github, opendev, launchpad" in err


# --- apply: clone paths --------------------------------------------------------


def test_apply_clones_github_via_gh_shim(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bare, _ = make_remote(root, "rocks")
    write_repo_config(
        root,
        "sunbeam",
        core=[{"name": "rocks", "forge": "github", "url": str(bare)}],
    )
    assert main(["repos", "apply", "sunbeam"]) == 0
    clone = root / "git" / "rocks"
    assert (clone / ".git").is_dir()
    summary = read_summary(capsys)
    assert summary["repos"][0]["status"] == "cloned"
    assert summary["counts"] == {"cloned": 1}
    state = json.loads((root / ".state" / "repos-sunbeam.json").read_text())
    assert state["repos"][0]["name"] == "rocks"
    assert state["git_root"] == str(root / "git")


def test_apply_clones_launchpad_entry(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bare, _ = make_remote(root, "keystone")
    write_repo_config(
        root,
        "packaging",
        core=[{"name": "keystone", "forge": "launchpad", "url": str(bare)}],
    )
    assert main(["repos", "apply", "packaging"]) == 0
    clone = root / "git" / "keystone"
    assert (clone / ".git").is_dir()
    # launchpad entries get no gerrit remote.
    proc = subprocess.run(
        ["git", "-C", str(clone), "remote", "get-url", "gerrit"],
        capture_output=True,
    )
    assert proc.returncode != 0


def test_apply_opendev_wires_gerrit_remote(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bare, _ = make_remote(
        root, "sunbeam-charms", files={".gitreview": GITREVIEW_FILE}
    )
    write_repo_config(
        root,
        "sunbeam",
        core=[{"name": "sunbeam-charms", "forge": "opendev", "url": str(bare)}],
    )
    assert main(["repos", "apply", "sunbeam"]) == 0
    clone = root / "git" / "sunbeam-charms"
    assert git("-C", str(clone), "remote", "get-url", "gerrit") == (
        "ssh://alice@review.opendev.org:29418/openstack/sunbeam-charms.git"
    )
    assert git("-C", str(clone), "config", "gitreview.username") == "alice"


def test_apply_github_fork_of_adds_fork_remote(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write_json(root / "config" / "alice" / "config.json", {"github_handle": "alicegh"})
    bare, _ = make_remote(root, "rocks")
    write_repo_config(
        root,
        "sunbeam",
        core=[
            {
                "name": "rocks",
                "forge": "github",
                "url": str(bare),
                "fork_of": "canonical/rocks",
            }
        ],
    )
    assert main(["repos", "apply", "sunbeam"]) == 0
    clone = root / "git" / "rocks"
    assert (
        git("-C", str(clone), "remote", "get-url", "fork")
        == "git@github.com:alicegh/rocks.git"
    )
    assert git("-C", str(clone), "remote", "get-url", "origin") == str(bare)


def test_apply_fork_of_without_github_handle_is_an_error(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bare, _ = make_remote(root, "rocks")
    write_repo_config(
        root,
        "sunbeam",
        core=[
            {
                "name": "rocks",
                "forge": "github",
                "url": str(bare),
                "fork_of": "canonical/rocks",
            }
        ],
    )
    assert main(["repos", "apply", "sunbeam"]) == 1
    summary = read_summary(capsys)
    assert summary["repos"][0]["status"] == "error"
    assert "github_handle" in summary["repos"][0]["detail"]


# --- apply: update / idempotency -----------------------------------------------


def test_apply_twice_fetches_without_reclone(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bare, _ = make_remote(root, "sunbeam-charms")
    write_repo_config(
        root,
        "sunbeam",
        core=[{"name": "sunbeam-charms", "forge": "opendev", "url": str(bare)}],
    )
    assert main(["repos", "apply", "sunbeam"]) == 0
    capsys.readouterr()
    clone = root / "git" / "sunbeam-charms"
    marker = clone / ".git" / "CLONE-MARKER"
    marker.write_text("original clone", encoding="utf-8")
    assert main(["repos", "apply", "sunbeam"]) == 0
    summary = read_summary(capsys)
    assert summary["repos"][0]["status"] == "up-to-date"
    # The existing clone was reused, not re-cloned...
    assert marker.read_text(encoding="utf-8") == "original clone"
    # ...and its refs still track the fixture remote exactly.
    assert git("-C", str(clone), "rev-parse", "HEAD") == git(
        "-C", str(bare), "rev-parse", "main"
    )


def test_apply_ff_updates_after_remote_advance(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bare, work = make_remote(root, "keystone")
    write_repo_config(
        root,
        "packaging",
        core=[{"name": "keystone", "forge": "launchpad", "url": str(bare)}],
    )
    assert main(["repos", "apply", "packaging"]) == 0
    capsys.readouterr()
    remote_head = advance_remote(work, "README.md", "# keystone\nadvanced\n")
    assert main(["repos", "apply", "packaging"]) == 0
    summary = read_summary(capsys)
    assert summary["repos"][0]["status"] == "updated"
    clone = root / "git" / "keystone"
    assert git("-C", str(clone), "rev-parse", "HEAD") == remote_head


# --- apply: safety rails ---------------------------------------------------------


def test_apply_reports_dirty_clone_and_leaves_it(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bare, work = make_remote(root, "keystone")
    write_repo_config(
        root,
        "packaging",
        core=[{"name": "keystone", "forge": "launchpad", "url": str(bare)}],
    )
    assert main(["repos", "apply", "packaging"]) == 0
    capsys.readouterr()
    clone = root / "git" / "keystone"
    remote_head = advance_remote(work, "README.md", "# keystone\nadvanced\n")
    with (clone / "README.md").open("a", encoding="utf-8") as fh:
        fh.write("local uncommitted edit\n")
    (clone / "untracked.txt").write_text("scratch\n", encoding="utf-8")
    assert main(["repos", "apply", "packaging"]) == 0
    summary = read_summary(capsys)
    entry = summary["repos"][0]
    assert entry["status"] == "dirty"
    assert "untouched" in entry["detail"]
    # Still dirty and never fetched/reset: local edit and old HEAD remain.
    assert git("-C", str(clone), "status", "--porcelain") != ""
    assert "local uncommitted edit" in (clone / "README.md").read_text()
    assert git("-C", str(clone), "rev-parse", "HEAD") != remote_head


def test_apply_unknown_forge_exits_nonzero(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write_repo_config(
        root,
        "sunbeam",
        core=[{"name": "bad", "forge": "gitlab", "url": "https://example.com/bad"}],
    )
    assert main(["repos", "apply", "sunbeam"]) == 2
    assert "unknown forge 'gitlab'" in capsys.readouterr().err
    assert not (root / "git" / "bad").exists()
    assert not (root / ".state" / "repos-sunbeam.json").exists()


# --- apply: invocation shapes ----------------------------------------------------


def test_apply_without_name_applies_all_configured_profiles(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    sunbeam_bare, _ = make_remote(root, "sunbeam-charms")
    keystone_bare, _ = make_remote(root, "keystone")
    write_repo_config(
        root,
        "sunbeam",
        core=[{"name": "sunbeam-charms", "forge": "opendev", "url": str(sunbeam_bare)}],
    )
    write_repo_config(
        root,
        "packaging",
        core=[{"name": "keystone", "forge": "launchpad", "url": str(keystone_bare)}],
    )
    # Mirrors `just repos` with no argument: apply every configured profile.
    assert main(["repos", "apply"]) == 0
    assert (root / "git" / "sunbeam-charms" / ".git").is_dir()
    assert (root / "git" / "keystone" / ".git").is_dir()
    assert (root / ".state" / "repos-sunbeam.json").is_file()
    assert (root / ".state" / "repos-packaging.json").is_file()


def test_git_subprocesses_carry_timeouts(
    root: Path, shims: Path, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    bare, _ = make_remote(root, "rocks")
    write_repo_config(
        root,
        "sunbeam",
        core=[{"name": "rocks", "forge": "github", "url": str(bare)}],
    )
    timeouts: list[float | None] = []
    real_run = subprocess.run

    def spy(*args, **kwargs):  # type: ignore[no-untyped-def]
        timeouts.append(kwargs.get("timeout"))
        return real_run(*args, **kwargs)

    monkeypatch.setattr(repos.subprocess, "run", spy)
    assert main(["repos", "apply", "sunbeam"]) == 0
    assert timeouts, "apply must run git subprocesses"
    assert all(timeout is not None for timeout in timeouts)
