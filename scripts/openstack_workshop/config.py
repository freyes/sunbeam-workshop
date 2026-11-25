"""Deep-merge of the repo's config layers (draft decisions D-14, A-12).

Layer precedence (later layer wins):

    config/config.{json,yaml}  <-  config/local.{json,yaml}
        <-  config/<user>/config.{json,yaml}

Each layer slot is format-flexible via loader.load_doc: exactly one of
``<base>.json`` or ``<base>.yaml``; both present is a hard error naming
both paths. Dicts merge recursively; lists and scalars replace. Missing
layers are skipped without error. Per-instance scope now exists for VARS
layers under config/local/vars/instance/; identity config keeps no
per-instance layer (A-12).
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

from .loader import load_doc


def deep_merge(base: Any, overlay: Any) -> Any:
    """Merge overlay onto base: dicts recurse, lists/scalars replace."""
    if isinstance(base, dict) and isinstance(overlay, dict):
        merged = dict(base)
        for key, value in overlay.items():
            if key in merged:
                merged[key] = deep_merge(merged[key], value)
            else:
                merged[key] = value
        return merged
    return overlay


def config_layer_paths(root: Path, user: str) -> list[Path]:
    """Config layer base paths (suffix-less) in merge order; later wins."""
    return [
        root / "config" / "config",
        root / "config" / "local",
        root / "config" / user / "config",
    ]


def load_config(root: Path, user: str) -> dict[str, Any]:
    """Deep-merge the config layers under root, skipping missing layers."""
    merged: dict[str, Any] = {}
    for base in config_layer_paths(root, user):
        doc = load_doc(base, "identity config layer")
        if doc is None:
            continue
        merged = deep_merge(merged, doc.data)
    return merged
