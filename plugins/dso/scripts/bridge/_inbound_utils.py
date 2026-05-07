"""Utility functions for bridge-inbound: module loading and timestamp parsing."""

from __future__ import annotations

import importlib.util
import re
from datetime import datetime
from pathlib import Path
from types import ModuleType


def load_module_from_path(name: str, path: Path) -> ModuleType:
    """Load a Python module from a filesystem path via importlib."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        msg = f"Cannot load module from {path}"
        raise ImportError(msg)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


# Jira ISO 8601 format with milliseconds and timezone offset (no colon)
# e.g. "2026-03-21T10:00:00.000+0530" or "2026-03-21T10:00:00.000+0000"
_JIRA_TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?"
    r"([+-]\d{2}:?\d{2}|Z)$"
)


def _adf_to_text(value: "str | dict | None") -> str:
    """Convert Jira ADF (Atlassian Document Format) to plain text.

    Handles three input types:
    - None → empty string
    - str → returned unchanged (back-compat for plain-text descriptions)
    - dict → ADF doc: walks doc→content[paragraph|heading|listItem]→content[text].text,
      joins paragraph texts with newlines; silently skips unsupported node types
      (panels, mediaSingle, mentions, inlineCard, mediaGroup, etc.)
    """
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if not isinstance(value, dict):
        return ""
    # ADF structure: {"type": "doc", "content": [...nodes...]}
    parts: list[str] = []
    for node in value.get("content", []):
        node_type = node.get("type", "")
        if node_type in ("paragraph", "heading", "listItem"):
            texts = [
                child.get("text", "")
                for child in node.get("content", [])
                if child.get("type") == "text" and child.get("text")
            ]
            if texts:
                parts.append("".join(texts))
        # All other node types are silently skipped
    return "\n".join(parts)


def parse_jira_timestamp(ts_str: str) -> datetime:
    """Parse a Jira ISO 8601 timestamp string to a timezone-aware datetime.

    Handles formats like:
        2026-03-21T10:00:00.000+0530
        2026-03-21T10:00:00.000+00:00
        2026-03-21T10:00:00Z
    """
    m = _JIRA_TS_RE.match(ts_str)
    if not m:
        return datetime.fromisoformat(ts_str)

    base = m.group(1)
    tz_part = m.group(2)

    if tz_part == "Z":
        tz_part = "+00:00"
    elif len(tz_part) == 5 and ":" not in tz_part:
        # Convert +0530 -> +05:30
        tz_part = tz_part[:3] + ":" + tz_part[3:]

    iso_str = f"{base}{tz_part}"
    return datetime.fromisoformat(iso_str)
