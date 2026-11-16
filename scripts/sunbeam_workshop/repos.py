"""Per-profile multi-forge repository manager (plan todo 11; A-7, D-6).

Repo sets are data, not code: ``config/repos/<profile>.{json,yaml}`` holds
``core_repos`` and ``supporting_repos`` lists of entries shaped
``{name, forge: github|opendev|launchpad, url, fork_of?}``.

Per forge:

* github    - clone with ``gh repo clone <url> <dest>``; when ``fork_of`` is
              set, add a ``fork`` remote at ``git@github.com:<handle>/<name>``
              (handle from the merged config's ``github_handle``).
* opendev   - https clone from the entry url, then ``git review -s`` inside
              the clone to wire the gerrit remote (``gitreview.username``
              from the vars doc: ``config.gerrit_username`` or the user name).
* launchpad - https clone from the entry url.

All clones live under ``/project/git/<repo>`` (A-7), overridable with
``--git-root`` or ``SUNBEAM_WORKSHOP_GIT_ROOT`` (tests use local fixtures).
Existing clones are fetched and fast-forwarded, never re-cloned; dirty
clones are reported and left completely untouched (never reset). Cloning is
https-only - ssh is for push via agent forwarding. Concurrency is a
ThreadPoolExecutor with at most 4 workers. A structured summary is printed
and written to ``.state/repos-<name>.json``.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from .loader import DocError, load_doc
from .vars import VarsError, build_vars, find_root

VALID_FORGES = ("github", "opendev", "launchpad")
CONFIG_SECTIONS = ("core_repos", "supporting_repos")
MAX_WORKERS = 4
CLONE_TIMEOUT = 900
FETCH_TIMEOUT = 600
OP_TIMEOUT = 60
DEFAULT_GIT_ROOT = Path("/project/git")
GIT_ROOT_ENV = "SUNBEAM_WORKSHOP_GIT_ROOT"

# Repo directory names double as paths under the git root: keep them boring.
NAME_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")


class ReposError(Exception):
    """Config or validation failure; exit_code is used by the CLI."""

    exit_code = 2


def resolve_git_root(cli_value: str | None) -> Path:
    """--git-root flag, then SUNBEAM_WORKSHOP_GIT_ROOT, then /project/git."""
    if cli_value:
        return Path(cli_value)
    return Path(os.environ.get(GIT_ROOT_ENV, str(DEFAULT_GIT_ROOT)))


def _run(
    cmd: list[str], *, cwd: Path | None = None, timeout: int
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd, cwd=cwd, timeout=timeout, text=True, capture_output=True
    )


def _git(
    dest: Path, *args: str, timeout: int = OP_TIMEOUT
) -> subprocess.CompletedProcess[str]:
    return _run(["git", "-C", str(dest), *args], timeout=timeout)


def _validate_entry(path: Path, section: str, index: int, entry: Any) -> dict:
    where = f"{path}: {section}[{index}]"
    if not isinstance(entry, dict):
        raise ReposError(f"{where} must be a JSON object")
    name = entry.get("name")
    if not isinstance(name, str) or not name:
        raise ReposError(f"{where} requires a non-empty string 'name'")
    if (
        not NAME_PATTERN.fullmatch(name)
        or ".." in name
        or name in (".", "..")
    ):
        raise ReposError(
            f"{where}: invalid repo name {name!r} "
            f"(must match {NAME_PATTERN.pattern}, no '..')"
        )
    forge = entry.get("forge")
    if forge not in VALID_FORGES:
        raise ReposError(
            f"{where}: repo {name!r}: unknown forge {forge!r} "
            f"(valid: {', '.join(VALID_FORGES)})"
        )
    url = entry.get("url")
    if not isinstance(url, str) or not url:
        raise ReposError(f"{where}: repo {name!r} requires a non-empty string 'url'")
    fork_of = entry.get("fork_of")
    if fork_of is not None and (not isinstance(fork_of, str) or not fork_of):
        raise ReposError(
            f"{where}: repo {name!r}: 'fork_of' must be a non-empty string when set"
        )
    return entry


def load_repo_config(root: Path, profile: str) -> dict[str, Any]:
    """Load and validate config/repos/<profile>.{json,yaml} (data, not code)."""
    base = root / "config" / "repos" / profile
    doc = load_doc(base, f"repo list for profile {profile!r}")
    if doc is None:
        raise ReposError(
            f"no repo config for profile {profile!r}: expected {base}.json "
            f"or {base}.yaml "
            f"(seed one from profiles/{profile}/vars.json core_repos)"
        )
    data = doc.data
    for section in CONFIG_SECTIONS:
        entries = data.get(section, [])
        if not isinstance(entries, list):
            raise ReposError(f"{doc.path}: {section} must be a list")
        for index, entry in enumerate(entries):
            _validate_entry(doc.path, section, index, entry)
    return data


def configured_profiles(root: Path) -> list[str]:
    """Profiles that have a config/repos/<profile>.{json,yaml} file.

    Both ``*.json`` and ``*.yaml`` are discovered and stems are deduped:
    the same stem in both formats is listed once here; load_doc raises the
    coexistence DocError when that profile is actually loaded.
    """
    repos_dir = root / "config" / "repos"
    if not repos_dir.is_dir():
        return []
    stems = {
        path.stem
        for pattern in ("*.json", "*.yaml")
        for path in repos_dir.glob(pattern)
    }
    return sorted(stems)


def _normalize_url(url: str) -> str:
    """Normalize a git URL for origin/config comparison."""
    normalized = url.rstrip("/")
    if normalized.endswith(".git"):
        normalized = normalized[: -len(".git")]
    return normalized


def _is_dirty(dest: Path) -> bool:
    proc = _git(dest, "status", "--porcelain")
    return proc.returncode == 0 and proc.stdout.strip() != ""


def _clone(entry: dict, git_root: Path) -> str | None:
    """Clone one entry; returns an error detail or None on success."""
    dest = git_root / entry["name"]
    if entry["forge"] == "github":
        cmd = ["gh", "repo", "clone", entry["url"], str(dest)]
    else:
        cmd = ["git", "clone", entry["url"], str(dest)]
    proc = _run(cmd, timeout=CLONE_TIMEOUT)
    if proc.returncode != 0:
        return f"clone failed (exit {proc.returncode}): {proc.stderr.strip()}"
    return None


def _wire_remotes(
    entry: dict, dest: Path, *, github_handle: str | None, gerrit_user: str
) -> tuple[list[str], str | None]:
    """Idempotent fork/gerrit remote wiring; returns (notes, error)."""
    notes: list[str] = []
    if entry["forge"] == "github" and entry.get("fork_of"):
        if not github_handle:
            return notes, (
                "fork_of is set but github_handle is not configured "
                "(set it in config/config.json or config/<user>/config.json)"
            )
        fork_url = f"git@github.com:{github_handle}/{entry['name']}.git"
        current = _git(dest, "remote", "get-url", "fork")
        if current.returncode != 0:
            proc = _git(dest, "remote", "add", "fork", fork_url)
            if proc.returncode != 0:
                return notes, f"adding fork remote failed: {proc.stderr.strip()}"
            notes.append(f"fork -> {fork_url}")
        elif current.stdout.strip() != fork_url:
            proc = _git(dest, "remote", "set-url", "fork", fork_url)
            if proc.returncode != 0:
                return notes, f"updating fork remote failed: {proc.stderr.strip()}"
            notes.append(f"fork updated -> {fork_url}")
        else:
            notes.append(f"fork -> {fork_url}")
    if entry["forge"] == "opendev":
        proc = _git(dest, "config", "gitreview.username", gerrit_user)
        if proc.returncode != 0:
            return notes, f"setting gitreview.username failed: {proc.stderr.strip()}"
        # git-review -s wires the gerrit remote from the repo's .gitreview.
        proc = _run(["git", "review", "-s"], cwd=dest, timeout=OP_TIMEOUT)
        if proc.returncode != 0:
            return notes, f"git review -s failed: {proc.stderr.strip()}"
        notes.append(f"gerrit wired for {gerrit_user}")
    return notes, None


def apply_entry(
    entry: dict,
    git_root: Path,
    *,
    github_handle: str | None,
    gerrit_user: str,
) -> dict[str, Any]:
    """Clone or fetch/ff-update one entry; never delete or reset anything."""
    name = entry["name"]
    dest = git_root / name
    result: dict[str, Any] = {
        "name": name,
        "forge": entry["forge"],
        "url": entry["url"],
        "path": str(dest),
        "status": "",
        "detail": "",
    }
    try:
        if not dest.exists():
            git_root.mkdir(parents=True, exist_ok=True)
            error = _clone(entry, git_root)
            if error:
                result.update(status="error", detail=error)
                return result
            result["status"] = "cloned"
        else:
            if not (dest / ".git").exists():
                result.update(
                    status="error",
                    detail="path exists but is not a git clone; leaving untouched",
                )
                return result
            origin = _git(dest, "remote", "get-url", "origin")
            if (
                origin.returncode == 0
                and _normalize_url(origin.stdout.strip())
                != _normalize_url(entry["url"])
            ):
                result.update(
                    status="error",
                    detail=(
                        f"origin is {origin.stdout.strip()} but config says "
                        f"{entry['url']}; leaving untouched"
                    ),
                )
                return result
            if _is_dirty(dest):
                result.update(
                    status="dirty",
                    detail="working tree has uncommitted changes; left untouched",
                )
                return result
            before = _git(dest, "rev-parse", "HEAD").stdout.strip()
            proc = _git(dest, "fetch", "--prune", "origin", timeout=FETCH_TIMEOUT)
            if proc.returncode != 0:
                result.update(
                    status="error", detail=f"fetch failed: {proc.stderr.strip()}"
                )
                return result
            branch = _git(dest, "symbolic-ref", "--short", "-q", "HEAD").stdout.strip()
            status = "fetched"
            if branch and _git(
                dest, "rev-parse", "--verify", "-q", f"origin/{branch}"
            ).returncode == 0:
                proc = _git(dest, "merge", "--ff-only", f"origin/{branch}")
                if proc.returncode != 0:
                    result.update(
                        status="diverged",
                        detail=(
                            f"cannot fast-forward {branch} to origin/{branch}; "
                            "left untouched"
                        ),
                    )
                    return result
                after = _git(dest, "rev-parse", "HEAD").stdout.strip()
                status = "updated" if after != before else "up-to-date"
            elif not branch:
                status = "up-to-date"
                result["detail"] = "detached HEAD; fetched only"
            result["status"] = status
        notes, error = _wire_remotes(
            entry, dest, github_handle=github_handle, gerrit_user=gerrit_user
        )
        if error:
            result.update(status="error", detail=error)
            return result
        detail = "; ".join(filter(None, [result["detail"], "; ".join(notes)]))
        result["detail"] = detail
        return result
    except subprocess.TimeoutExpired as exc:
        cmd = " ".join(str(part) for part in exc.cmd) if exc.cmd else "subprocess"
        result.update(status="error", detail=f"timed out after {exc.timeout}s: {cmd}")
        return result


def list_doc(root: Path, name: str) -> dict[str, Any]:
    """Validated repo config for the workshop NAME as a JSON-able doc."""
    vars_doc = build_vars(root, name)
    profile = vars_doc["profile"]
    data = load_repo_config(root, profile)
    return {
        "workshop": name,
        "profile": profile,
        "core_repos": data.get("core_repos", []),
        "supporting_repos": data.get("supporting_repos", []),
    }


def apply_profile(root: Path, name: str, git_root: Path) -> tuple[dict[str, Any], int]:
    """Clone/update every repo for NAME; returns (summary, exit_code)."""
    vars_doc = build_vars(root, name)
    profile = vars_doc["profile"]
    data = load_repo_config(root, profile)
    github_handle = vars_doc["user"]["github_handle"]
    gerrit_user = vars_doc["config"].get("gerrit_username") or vars_doc["user"]["name"]
    entries = [
        entry
        for section in CONFIG_SECTIONS
        for entry in data.get(section, [])
    ]
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        results = list(
            pool.map(
                lambda entry: apply_entry(
                    entry,
                    git_root,
                    github_handle=github_handle,
                    gerrit_user=gerrit_user,
                ),
                entries,
            )
        )
    counts: dict[str, int] = {}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    summary: dict[str, Any] = {
        "workshop": name,
        "profile": profile,
        "git_root": str(git_root),
        "counts": counts,
        "repos": results,
    }
    state_dir = root / ".state"
    state_dir.mkdir(mode=0o700, exist_ok=True)
    state_path = state_dir / f"repos-{name}.json"
    summary["state_file"] = str(state_path)
    state_path.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    exit_code = 1 if counts.get("error") else 0
    return summary, exit_code


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sunbeam_workshop repos",
        description="Per-profile multi-forge repo clone/update (github, opendev, launchpad).",
    )
    subparsers = parser.add_subparsers(dest="action", required=True)
    list_parser = subparsers.add_parser(
        "list", help="print the validated repo config for NAME as JSON"
    )
    list_parser.add_argument(
        "name",
        nargs="?",
        default=None,
        metavar="NAME",
        help="workshop name (default: every configured profile)",
    )
    apply_parser = subparsers.add_parser(
        "apply", help="clone or fetch/ff-update the repos for NAME"
    )
    apply_parser.add_argument(
        "name",
        nargs="?",
        default=None,
        metavar="NAME",
        help="workshop name (default: every configured profile)",
    )
    apply_parser.add_argument(
        "--git-root",
        default=None,
        metavar="PATH",
        help=f"clone root (default: ${GIT_ROOT_ENV} or {DEFAULT_GIT_ROOT})",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = find_root(Path.cwd())
    try:
        names = [args.name] if args.name else configured_profiles(root)
        if not names:
            raise ReposError(
                "no config/repos/*.{json,yaml} found; nothing to do"
            )
        exit_code = 0
        for name in names:
            if args.action == "list":
                doc = list_doc(root, name)
            else:
                doc, code = apply_profile(
                    root, name, resolve_git_root(args.git_root)
                )
                exit_code = max(exit_code, code)
            json.dump(doc, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
        return exit_code
    except VarsError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return exc.exit_code
    except ReposError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return exc.exit_code
    except DocError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
