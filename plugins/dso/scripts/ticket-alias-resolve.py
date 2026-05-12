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


def load_wordlist(path: str) -> tuple[list[str], list[str]]:
    adjs: list[str] = []
    nouns: list[str] = []
    section = "adj"
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line == "# NOUNS":
                    section = "noun"
                    continue
                if line.startswith("#") or not line.strip():
                    continue
                (adjs if section == "adj" else nouns).append(line.strip())
    except OSError:
        pass
    return adjs, nouns


def compute_alias(ticket_id: str, adjs: list[str], nouns: list[str]) -> str | None:
    """Mirror of ticket_reducer._alias.compute_alias — kept inline so this
    helper has no dependency on the reducer package import path."""
    hex_id = ticket_id.replace("-", "")
    if len(hex_id) < 8 or not adjs or not nouns:
        return None
    try:
        adj = adjs[int(hex_id[0:4], 16) % len(adjs)]
        n1 = nouns[int(hex_id[4:8], 16) % len(nouns)]
    except ValueError:
        return None
    if len(hex_id) >= 12:
        try:
            n2 = nouns[int(hex_id[8:12], 16) % len(nouns)]
            return f"{adj}-{n1}-{n2}"
        except ValueError:
            pass
    return f"{adj}-{n1}"


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input> <tracker_dir>", file=sys.stderr)
        return 1
    target = sys.argv[1]
    tracker = sys.argv[2]

    here = os.path.dirname(os.path.abspath(__file__))
    wordlist = os.environ.get("TICKET_WORDLIST_PATH") or os.path.normpath(
        os.path.join(here, "..", "resources", "ticket-wordlist.txt")
    )
    adjs, nouns = load_wordlist(wordlist)

    try:
        entries = sorted(os.listdir(tracker))
    except OSError:
        return 0

    for name in entries:
        if name.startswith("."):
            continue
        ticket_dir = os.path.join(tracker, name)
        if not os.path.isdir(ticket_dir):
            continue
        # Find the CREATE event (typically one per ticket)
        create_path = None
        try:
            for fname in os.listdir(ticket_dir):
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
        # alias match — stored or backfilled
        effective_alias = stored_alias or compute_alias(name, adjs, nouns) or ""
        if effective_alias and effective_alias == target:
            print(f"alias\t{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
