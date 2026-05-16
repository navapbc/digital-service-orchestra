"""Shared Python ticket-ID resolver.

Mirrors ``plugins/dso/scripts/ticket-lib.sh::resolve_ticket_id`` so Python
CLIs accept the same ID forms (full 16-hex, 8-hex short, alias, jira_key,
unique prefix >= 4 chars) as the bash dispatcher does.

Delegates alias/jira_key lookup to ``ticket-alias-resolve.py`` — the same
helper the bash resolver uses — so a stored ``data.alias`` or
``data.jira_key`` in any CREATE event is reachable from both sides without
drift.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent

_FULL_ID_RE = re.compile(r"^[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$")
_SHORT_ID_RE = re.compile(r"^[a-z0-9]{4}-[a-z0-9]{4}$")


def resolve_ticket_id(ticket_id: str, tracker_dir: str) -> str | None:
    """Return the canonical ticket directory name for ``ticket_id``, or None."""
    if _FULL_ID_RE.match(ticket_id):
        return ticket_id if os.path.isdir(os.path.join(tracker_dir, ticket_id)) else None

    if _SHORT_ID_RE.match(ticket_id):
        if os.path.isdir(os.path.join(tracker_dir, ticket_id)):
            return ticket_id
        try:
            matches = [
                n for n in os.listdir(tracker_dir)
                if not n.startswith(".")
                and n[:9] == ticket_id
                and os.path.isdir(os.path.join(tracker_dir, n))
            ]
        except OSError:
            return None
        return matches[0] if len(matches) == 1 else None

    resolver = _SCRIPT_DIR / "ticket-alias-resolve.py"
    if resolver.is_file():
        try:
            result = subprocess.run(
                [sys.executable, str(resolver), ticket_id, tracker_dir],
                capture_output=True, text=True, timeout=30, check=False,
            )
        except (subprocess.SubprocessError, OSError):
            result = None
        if result is not None and result.returncode == 0:
            alias_matches: list[str] = []
            jira_matches: list[str] = []
            for line in result.stdout.splitlines():
                if "\t" in line:
                    kind, tid = line.split("\t", 1)
                    if kind == "jira":
                        jira_matches.append(tid)
                    elif kind == "alias":
                        alias_matches.append(tid)
            if len(jira_matches) == 1:
                return jira_matches[0]
            if jira_matches:
                return None
            if len(alias_matches) == 1:
                return alias_matches[0]
            if alias_matches:
                return None

    if len(ticket_id) >= 4:
        try:
            matches = [
                n for n in os.listdir(tracker_dir)
                if not n.startswith(".")
                and n.startswith(ticket_id)
                and os.path.isdir(os.path.join(tracker_dir, n))
            ]
        except OSError:
            return None
        if len(matches) == 1:
            return matches[0]

    return None
