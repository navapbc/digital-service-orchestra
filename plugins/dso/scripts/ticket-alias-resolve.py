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
        # Also locate the lexically-latest SNAPSHOT event (excluding
        # PRECONDITIONS-SNAPSHOT) so that compacted tickets — where the
        # CREATE event has been folded into a SNAPSHOT — still expose the
        # authoritative alias/jira_key from compiled_state.  Bug
        # 9894-a463-090a-43e5: the wordlist evolves over time, so
        # compute_alias(ticket_id) can diverge from the alias that was
        # stored on the original CREATE event; for compacted tickets the
        # SNAPSHOT's compiled_state.alias is the authoritative value and
        # must take precedence over the backfill.
        create_path = None
        snapshot_path = None
        try:
            for fname in sorted(os.listdir(ticket_dir)):
                if fname.endswith("-CREATE.json") and create_path is None:
                    create_path = os.path.join(ticket_dir, fname)
                elif fname.endswith("-SNAPSHOT.json") and not fname.endswith(
                    "-PRECONDITIONS-SNAPSHOT.json"
                ):
                    # Track the lexically-latest SNAPSHOT (sorted() yields
                    # ascending order, so a later filename overwrites earlier).
                    snapshot_path = os.path.join(ticket_dir, fname)
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
        # SNAPSHOT-only path: when no CREATE event provided an alias/jira_key
        # (either because the CREATE is absent — compacted ticket — or its
        # data.alias was empty), read compiled_state from the latest SNAPSHOT.
        # This MUST run before the compute_alias backfill so the wordlist
        # cannot override the authoritative stored value.
        if snapshot_path and (not stored_alias or not jira_key):
            try:
                with open(snapshot_path, encoding="utf-8") as f:
                    snap_data = json.load(f).get("data", {}) or {}
                snap_state = snap_data.get("compiled_state", {}) or {}
                if not stored_alias:
                    stored_alias = snap_state.get("alias") or ""
                if not jira_key:
                    jira_key = snap_state.get("jira_key") or ""
            except (OSError, json.JSONDecodeError):
                pass
        # jira_key match
        if jira_key and jira_key == target:
            print(f"jira\t{name}")
            continue
        # alias match — stored (CREATE or SNAPSHOT) or backfilled.  Backfill
        # only fires when no event has supplied a stored alias; once a
        # SNAPSHOT has recorded compiled_state.alias, that value is the
        # source of truth and compute_alias is irrelevant.
        effective_alias = stored_alias or compute_alias(name) or ""
        if effective_alias and effective_alias == target:
            print(f"alias\t{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
