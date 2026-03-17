#!/usr/bin/env python3
"""
merge-ticket-index.py — Custom Git merge driver for .tickets/.index.json

Performs a pure-Python JSON union merge of .tickets/.index.json when two branches
both modify the file. Git invokes this driver with three positional arguments:
  ancestor (%O)  — path to common ancestor version
  ours (%A)      — path to our version (ALSO the output path)
  theirs (%B)    — path to their version

The merge strategy is:
  1. Load all three JSON objects (must be dicts).
  2. Start with a copy of the ancestor.
  3. Apply ours changes: add/update keys present in ours but not ancestor, or
     changed relative to ancestor.
  4. Apply theirs changes: add/update keys present in theirs but not ancestor, or
     changed relative to ancestor.
  5. When both ours and theirs modify the same key to different non-ancestor values,
     THEIRS wins. This matches git merge convention (theirs = incoming branch).
  6. Write the result to the ours file (%A) with sorted keys and 2-space indent.

Emits structured log line to stderr:
  MERGE_AUTO_RESOLVE: path=.tickets/.index.json layer=driver

Usage:
  merge-ticket-index.py <ancestor> <ours> <theirs>
  merge-ticket-index.py --help

Git config registration (per-clone, run once):
  git config merge.tickets-index-merge.driver \\
    "python3 /path/to/merge-ticket-index.py %O %A %B"
  git config merge.tickets-index-merge.name "Ticket index JSON union merge"

.gitattributes entry:
  .tickets/.index.json merge=tickets-index-merge
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_json(path: str) -> dict[str, Any]:
    """Load and return a JSON object from path. Raises SystemExit on error."""
    p = Path(path)
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: Cannot read file '{path}': {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        print(
            f"ERROR: Invalid JSON in '{path}': {exc}",
            file=sys.stderr,
        )
        sys.exit(1)

    if not isinstance(data, dict):
        print(
            f"ERROR: Expected a JSON object (dict) in '{path}', "
            f"got {type(data).__name__}",
            file=sys.stderr,
        )
        sys.exit(1)

    return data


def merge_ticket_index(
    ancestor: dict[str, Any],
    ours: dict[str, Any],
    theirs: dict[str, Any],
) -> dict[str, Any]:
    """
    Perform a three-way JSON union merge.

    Conflict resolution: when both ours and theirs modify the same key to
    different non-ancestor values, THEIRS wins (matches git merge convention).

    Returns the merged dict.
    """
    # Start with all keys from all versions
    all_keys = set(ancestor) | set(ours) | set(theirs)
    result: dict[str, Any] = {}

    for key in all_keys:
        in_ours = key in ours
        in_theirs = key in theirs

        ancestor_val = ancestor.get(key)
        ours_val = ours.get(key)
        theirs_val = theirs.get(key)

        if not in_ours and not in_theirs:
            # Only in ancestor — deleted by both; skip
            continue
        elif not in_ours:
            # Only theirs has it (or theirs added it); use theirs
            result[key] = theirs_val
        elif not in_theirs:
            # Only ours has it (or ours added it); use ours
            result[key] = ours_val
        else:
            # Both ours and theirs have the key
            ours_changed = ours_val != ancestor_val
            theirs_changed = theirs_val != ancestor_val

            if not ours_changed and not theirs_changed:
                # Neither changed — use ancestor value
                result[key] = ancestor_val
            elif ours_changed and not theirs_changed:
                # Only ours changed — use ours
                result[key] = ours_val
            elif not ours_changed and theirs_changed:
                # Only theirs changed — use theirs
                result[key] = theirs_val
            else:
                # Both changed — THEIRS wins (git merge convention)
                result[key] = theirs_val

    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Custom Git merge driver for .tickets/.index.json. "
            "Performs a pure-Python JSON union merge. "
            "Git invokes with: ancestor(%O) ours(%A) theirs(%B). "
            "Writes merged result to the ours(%A) file."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("ancestor", help="Path to ancestor version (%%O)")
    parser.add_argument(
        "ours",
        help="Path to our version (%%A) — also the output path",
    )
    parser.add_argument("theirs", help="Path to their version (%%B)")

    args = parser.parse_args()

    ancestor = load_json(args.ancestor)
    ours = load_json(args.ours)
    theirs = load_json(args.theirs)

    merged = merge_ticket_index(ancestor, ours, theirs)

    # Write result to ours file (sorted keys, 2-space indent, trailing newline)
    output = json.dumps(merged, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    try:
        Path(args.ours).write_text(output, encoding="utf-8")
    except OSError as exc:
        print(
            f"ERROR: Cannot write merged result to '{args.ours}': {exc}",
            file=sys.stderr,
        )
        sys.exit(1)

    # Emit structured log line to stderr
    print(
        "MERGE_AUTO_RESOLVE: path=.tickets/.index.json layer=driver",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
