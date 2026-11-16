"""Format-flexible data-doc loader: one slot, JSON or YAML, never both.

A data-doc slot is a filesystem base path without an extension. Exactly two
candidate files are consulted: ``<base>.json`` and ``<base>.yaml`` (``.yml``
is never consulted). When both exist the slot is ambiguous and DocError
names both paths and the slot purpose. JSON is parsed with :mod:`json`;
YAML with ``yaml.safe_load`` only. An empty or whitespace-only file yields
``{}`` uniformly for both formats (the content is checked before parsing).
Any other parse failure raises DocError naming the path, with the parser's
line/column when available. The parsed top level must be a dict. When
neither file exists, ``load_doc`` returns None.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import yaml


class DocError(Exception):
    """A data doc is ambiguous, unreadable, unparseable, or not a mapping."""


@dataclass(frozen=True)
class LoadedDoc:
    """A loaded data doc: parsed data, source path, format, byte digest."""

    data: dict[str, Any]
    path: Path
    format: Literal["json", "yaml"]
    digest: str  # sha256 hex of the raw file bytes


def _parse_json(path: Path, text: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise DocError(
            f"{path}: invalid JSON: {exc.msg} "
            f"(line {exc.lineno}, column {exc.colno})"
        ) from exc


def _parse_yaml(path: Path, text: str) -> Any:
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as exc:
        problem = getattr(exc, "problem", None) or str(exc).splitlines()[0]
        mark = getattr(exc, "problem_mark", None)
        where = f" (line {mark.line + 1}, column {mark.column + 1})" if mark else ""
        raise DocError(f"{path}: invalid YAML: {problem}{where}") from exc


def load_doc(base: Path, purpose: str) -> LoadedDoc | None:
    """Load the data doc at slot ``base``; None when neither file exists.

    ``purpose`` is a human-readable slot description used in the
    coexistence error message (e.g. "identity config layer").
    """
    json_path = base.parent / f"{base.name}.json"
    yaml_path = base.parent / f"{base.name}.yaml"
    has_json = json_path.is_file()
    has_yaml = yaml_path.is_file()
    if has_json and has_yaml:
        raise DocError(
            f"{purpose}: both {json_path} and {yaml_path} exist; "
            "keep exactly one format per slot (.yml is never consulted)"
        )
    if not has_json and not has_yaml:
        return None
    path = json_path if has_json else yaml_path
    doc_format: Literal["json", "yaml"] = "json" if has_json else "yaml"
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise DocError(f"{path}: not valid UTF-8: {exc}") from exc
    if text.strip() == "":
        data: Any = {}
    elif doc_format == "json":
        data = _parse_json(path, text)
    else:
        data = _parse_yaml(path, text)
    if not isinstance(data, dict):
        raise DocError(
            f"{path}: top level must be a mapping, got {type(data).__name__}"
        )
    return LoadedDoc(data=data, path=path, format=doc_format, digest=digest)
