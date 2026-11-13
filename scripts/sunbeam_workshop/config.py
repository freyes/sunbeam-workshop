"""Deep-merge of the repo's JSON config layers (draft decisions D-14, A-12).

Layer precedence (later layer wins):

    config/config.json  <-  config/local.json  <-  config/<user>/config.json

Dicts merge recursively; lists and scalars replace. Missing layers are
skipped without error. There is no per-instance config layer (A-12).
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class ConfigError(Exception):
    """A config layer exists but is not a JSON object."""


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
    """Config layer paths in merge order (later layers win)."""
    return [
        root / "config" / "config.json",
        root / "config" / "local.json",
        root / "config" / user / "config.json",
    ]


def load_config(root: Path, user: str) -> dict[str, Any]:
    """Deep-merge the config layers under root, skipping missing layers."""
    merged: dict[str, Any] = {}
    for path in config_layer_paths(root, user):
        if not path.is_file():
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ConfigError(f"config layer {path} must be a JSON object")
        merged = deep_merge(merged, data)
    return merged
