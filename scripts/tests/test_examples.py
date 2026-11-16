"""Validate config/example/vars/ against the user vars strict schema.

The example layers are documentation: they must never drift invalid. Each
is loaded through the real loader (loader.load_doc, the same json|yaml
format-flexible path live layers use) and validated with
uservars.validate_layer, exactly as a layer under config/local/vars/
would be. A deliberately broken variant proves the gate rejects.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from sunbeam_workshop.loader import load_doc
from sunbeam_workshop.uservars import UserVarsError, merge, validate_layer

REPO_ROOT = Path(__file__).resolve().parents[2]
EXAMPLE_VARS = REPO_ROOT / "config" / "example" / "vars"

EXAMPLE_SLOTS = [
    EXAMPLE_VARS / "all",
    EXAMPLE_VARS / "profile" / "sunbeam",
]


@pytest.mark.parametrize("base", EXAMPLE_SLOTS)
def test_example_layer_validates(base: Path) -> None:
    """Each shipped example passes the strict layer schema."""
    doc = load_doc(base, "example user vars layer")
    assert doc is not None, f"example layer missing: {base}.yaml"
    validate_layer(doc)


def test_example_layers_merge_cleanly() -> None:
    """The examples merge without override warnings or conflicts."""
    docs = [load_doc(base, "example user vars layer") for base in EXAMPLE_SLOTS]
    _merged, warnings = merge([doc for doc in docs if doc is not None])
    assert warnings == []


def test_broken_example_variant_is_rejected(tmp_path: Path) -> None:
    """A deliberately broken variant of the example fails validation.

    The injected key is a snap pin: snap-pin overrides are out of scope
    (pins stay tracked-only), so `snaps` is an unknown top-level key and
    the strict schema must reject it, naming the path and the key.
    """
    base = tmp_path / "all"
    base.with_suffix(".yaml").write_text(
        (EXAMPLE_VARS / "all.yaml").read_text(encoding="utf-8") + "\nsnaps: {}\n",
        encoding="utf-8",
    )
    doc = load_doc(base, "broken example variant")
    assert doc is not None
    with pytest.raises(UserVarsError, match="unknown top-level key"):
        validate_layer(doc)
