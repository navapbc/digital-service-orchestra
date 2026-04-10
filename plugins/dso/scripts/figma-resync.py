#!/usr/bin/env python3
"""figma-resync.py — CLI entry point for Figma design re-sync workflow.

Orchestrates the full pull-back workflow: validates preconditions, acquires
file lock, calls pull (S2) then merge (S3), presents change summary for
user confirmation, handles tag transitions, and records sync metadata.

Usage:
    python3 figma-resync.py <ticket-id> [--non-interactive]

Arguments:
    ticket-id       DSO ticket ID with design:awaiting_review tag.
    --non-interactive   Skip confirmation prompt; auto-confirm for CI.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Make figma_resync importable when run as a script
_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from figma_resync import run  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Trigger Figma design re-sync: pull → merge → confirm → tag swap → metadata."
    )
    parser.add_argument(
        "ticket_id", help="DSO ticket ID with design:awaiting_review tag"
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Skip confirmation prompt; auto-confirm for CI",
    )
    parser.add_argument(
        "--manifest-dir",
        default=None,
        help="Directory containing spatial-layout.json, wireframe.svg, and tokens.md",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Output directory for merged artifacts (defaults to --manifest-dir)",
    )

    args = parser.parse_args(argv)
    return run(
        ticket_id=args.ticket_id,
        non_interactive=args.non_interactive,
        manifest_dir=args.manifest_dir,
        output_dir=args.output_dir,
    )


if __name__ == "__main__":
    sys.exit(main())
