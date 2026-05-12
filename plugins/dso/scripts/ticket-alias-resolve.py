#!/usr/bin/env python3
"""Single-pass alias / jira_key resolver for resolve_ticket_id.

Replaces the per-file Python loop in ticket-lib.sh resolve_ticket_id.
For each ticket directory, reads its CREATE event once and matches
against the input by:
  - data.alias (stored, set at create time for new tickets)
  - data.alias backfilled by computing from ticket_id (for legacy tickets)
  - data.jira_key

Output (one line per match):
  alias <ticket_dir_name>
  jira  <ticket_dir_name>

Exit code is always 0 — caller dedupes and chooses match precedence.

Usage:
    ticket-alias-resolve.py <input> <tracker_dir>
"""

from __future__ import annotations

import json
import os
import sys

# Single source of truth for alias computation lives in
# ticket_reducer/_alias.py. Importing it here keeps stored-at-create-time
# aliases and backfilled-at-resolve-time aliases in lock-step — the same
# wordlist, the same fallback rules, the same env var override.
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)
from ticket_reducer._alias import compute_alias  # noqa: E402


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input> <tracker_dir>", file=sys.stderr)
        return 1
    target = sys.argv[1]
    tracker = sys.argv[2]

    try:
        entries = sorted(os.listdir(tracker))
    except OSError as exc:
        # Fail loud — silent OSError here looks identical to "no matches"
        # and turns a debuggable I/O failure into a mysterious lookup miss.
        print(f"ticket-alias-resolve: cannot list {tracker!r}: {exc}", file=sys.stderr)
        return 1

    for name in entries:
        if name.startswith("."):
            continue
        ticket_dir = os.path.join(tracker, name)
        if not os.path.isdir(ticket_dir):
            continue
        # Find the first CREATE event (typically exactly one per ticket;
        # if multiple ever appear, the lexically earliest wins — same
        # ordering rule the rest of the reducer applies).
        create_path = None
        try:
            for fname in sorted(os.listdir(ticket_dir)):
                if fname.endswith("-CREATE.json"):
                    create_path = os.path.join(ticket_dir, fname)
                    break
        except OSError:
            continue
        stored_alias = ""
        jira_key = ""
        if create_path:
            try:
                with open(create_path, encoding="utf-8") as f:
                    data = json.load(f).get("data", {}) or {}
                stored_alias = data.get("alias") or ""
                jira_key = data.get("jira_key") or ""
            except (OSError, json.JSONDecodeError):
                pass
        # jira_key match
        if jira_key and jira_key == target:
            print(f"jira\t{name}")
            continue
        # alias match — stored or backfilled (compute_alias is the same
        # function ticket_reducer/_processors.process_create uses, so a
        # stored alias and a backfilled alias for the same ticket_id are
        # guaranteed to be identical).
        effective_alias = stored_alias or compute_alias(name) or ""
        if effective_alias and effective_alias == target:
            print(f"alias\t{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
