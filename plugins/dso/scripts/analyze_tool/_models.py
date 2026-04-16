"""Data structures for analyze-tool-use."""

from __future__ import annotations

import json
from typing import Any


class LogEntry:
    """A single parsed JSONL log entry."""

    __slots__ = (
        "ts",
        "epoch_ms",
        "session_id",
        "tool_name",
        "hook_type",
        "tool_input_summary",
        "exit_status",
        "raw",
    )

    def __init__(self, data: dict[str, Any]) -> None:
        self.ts: str = data.get("ts", "")
        self.epoch_ms: int = int(data.get("epoch_ms", 0))
        self.session_id: str = data.get("session_id", "")
        self.tool_name: str = data.get("tool_name", "")
        self.hook_type: str = data.get("hook_type", "")
        self.tool_input_summary: str = data.get("tool_input_summary", "")
        self.exit_status: int | None = data.get("exit_status")
        self.raw: dict[str, Any] = data

    def parsed_input(self) -> dict[str, Any]:
        """Try to parse tool_input_summary as JSON; return empty dict on failure."""
        try:
            return json.loads(self.tool_input_summary)
        except (json.JSONDecodeError, TypeError):
            return {}
