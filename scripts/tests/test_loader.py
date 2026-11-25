"""Tests for openstack_workshop.loader (format-flexible data docs).

All tests run against slots built under tmp_path. A slot is a suffix-less
base path; exactly ``<base>.json`` or ``<base>.yaml`` is consulted.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from openstack_workshop.loader import DocError, LoadedDoc, load_doc

PURPOSE = "test slot purpose"


def write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


# --- slot resolution ---------------------------------------------------------


def test_absent_slot_returns_none(tmp_path: Path) -> None:
    assert load_doc(tmp_path / "missing", PURPOSE) is None


def test_yml_is_never_consulted(tmp_path: Path) -> None:
    write(tmp_path / "slot.yml", "a: 1\n")
    assert load_doc(tmp_path / "slot", PURPOSE) is None


def test_both_formats_raise_naming_both_paths_and_purpose(
    tmp_path: Path,
) -> None:
    json_path = write(tmp_path / "slot.json", "{}")
    yaml_path = write(tmp_path / "slot.yaml", "{}\n")
    with pytest.raises(DocError) as excinfo:
        load_doc(tmp_path / "slot", PURPOSE)
    message = str(excinfo.value)
    assert str(json_path) in message
    assert str(yaml_path) in message
    assert PURPOSE in message


# --- happy paths -------------------------------------------------------------


def test_json_only(tmp_path: Path) -> None:
    raw = b'{"a": 1, "b": {"c": [1, 2]}}'
    path = write(tmp_path / "slot.json", raw.decode("utf-8"))
    doc = load_doc(tmp_path / "slot", PURPOSE)
    assert isinstance(doc, LoadedDoc)
    assert doc.data == {"a": 1, "b": {"c": [1, 2]}}
    assert doc.path == path
    assert doc.format == "json"
    assert doc.digest == hashlib.sha256(raw).hexdigest()


def test_yaml_only(tmp_path: Path) -> None:
    raw = b"a: 1\nb:\n  c:\n    - 1\n    - 2\n"
    path = write(tmp_path / "slot.yaml", raw.decode("utf-8"))
    doc = load_doc(tmp_path / "slot", PURPOSE)
    assert isinstance(doc, LoadedDoc)
    assert doc.data == {"a": 1, "b": {"c": [1, 2]}}
    assert doc.path == path
    assert doc.format == "yaml"
    assert doc.digest == hashlib.sha256(raw).hexdigest()


# --- parse failures ------------------------------------------------------------


def test_json_parse_error_names_path(tmp_path: Path) -> None:
    path = write(tmp_path / "slot.json", '{"a": }')
    with pytest.raises(DocError) as excinfo:
        load_doc(tmp_path / "slot", PURPOSE)
    assert str(path) in str(excinfo.value)


def test_yaml_parse_error_names_path(tmp_path: Path) -> None:
    path = write(tmp_path / "slot.yaml", "a: [1, 2\n")
    with pytest.raises(DocError) as excinfo:
        load_doc(tmp_path / "slot", PURPOSE)
    assert str(path) in str(excinfo.value)


def test_yaml_unsafe_tag_rejected_by_safe_load(tmp_path: Path) -> None:
    # yaml.safe_load only: a python/object tag is a DocError, never executed.
    path = write(tmp_path / "slot.yaml", "x: !!python/object/new:os.system ['id']\n")
    with pytest.raises(DocError) as excinfo:
        load_doc(tmp_path / "slot", PURPOSE)
    assert str(path) in str(excinfo.value)


# --- top-level shape -----------------------------------------------------------


@pytest.mark.parametrize(
    ("filename", "content"),
    [
        ("slot.json", "[1, 2]"),
        ("slot.yaml", "- a\n- b\n"),
    ],
    ids=["json-list", "yaml-list"],
)
def test_top_level_list_rejected(
    tmp_path: Path, filename: str, content: str
) -> None:
    path = write(tmp_path / filename, content)
    with pytest.raises(DocError) as excinfo:
        load_doc(tmp_path / "slot", PURPOSE)
    assert str(path) in str(excinfo.value)


@pytest.mark.parametrize(
    ("filename", "content"),
    [
        ("slot.json", "42"),
        ("slot.yaml", "just a scalar\n"),
        ("slot.yaml", "null\n"),
    ],
    ids=["json-scalar", "yaml-scalar", "yaml-null"],
)
def test_top_level_scalar_rejected(
    tmp_path: Path, filename: str, content: str
) -> None:
    path = write(tmp_path / filename, content)
    with pytest.raises(DocError) as excinfo:
        load_doc(tmp_path / "slot", PURPOSE)
    assert str(path) in str(excinfo.value)


# --- empty / whitespace-only -----------------------------------------------------


@pytest.mark.parametrize("filename", ["slot.json", "slot.yaml"])
def test_empty_file_yields_empty_dict(tmp_path: Path, filename: str) -> None:
    write(tmp_path / filename, "")
    doc = load_doc(tmp_path / "slot", PURPOSE)
    assert doc is not None
    assert doc.data == {}
    assert doc.digest == hashlib.sha256(b"").hexdigest()


@pytest.mark.parametrize("filename", ["slot.json", "slot.yaml"])
def test_whitespace_only_yields_empty_dict(tmp_path: Path, filename: str) -> None:
    write(tmp_path / filename, "  \n\t \n")
    doc = load_doc(tmp_path / "slot", PURPOSE)
    assert doc is not None
    assert doc.data == {}


# --- digest -----------------------------------------------------------------------


def test_digest_stable_across_calls(tmp_path: Path) -> None:
    write(tmp_path / "slot.json", '{"a": 1}')
    first = load_doc(tmp_path / "slot", PURPOSE)
    second = load_doc(tmp_path / "slot", PURPOSE)
    assert first is not None and second is not None
    assert first.digest == second.digest


def test_digest_distinct_per_format(tmp_path: Path) -> None:
    write(tmp_path / "jsonslot.json", '{"a": 1}')
    write(tmp_path / "yamlslot.yaml", "a: 1\n")
    json_doc = load_doc(tmp_path / "jsonslot", PURPOSE)
    yaml_doc = load_doc(tmp_path / "yamlslot", PURPOSE)
    assert json_doc is not None and yaml_doc is not None
    assert json_doc.data == yaml_doc.data  # same data...
    assert json_doc.digest != yaml_doc.digest  # ...different raw bytes
