#!/usr/bin/env python3
"""scratch-measure-token-reduction.py

Measurement harness for token-reduction analysis.

This module provides the config loader and CLI skeleton.  Measurement logic
is added by sibling tasks; this file must NOT pre-implement it.

Usage:
    python3 scratch-measure-token-reduction.py --config <path> [--check-config]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

REQUIRED_FIELDS = [
    "test_epic_id",
    "tokenizer",
    "pre_head_sha",
    "post_head_sha",
    "output_path",
]


def _load_yaml(path: str) -> dict:
    """Load a YAML file, preferring PyYAML when available.

    Falls back to a minimal inline parser for the small, flat schema used by
    this harness when PyYAML is not installed.
    """
    try:
        import yaml  # type: ignore[import-untyped]

        with open(path) as fh:
            return yaml.safe_load(fh) or {}
    except ImportError:
        pass

    # Minimal inline YAML parser: handles "key: value" lines only.
    # Sufficient for the known flat schema; rejects multi-line / nested blocks.
    result: dict = {}
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if ":" not in line:
                print(
                    f"ERROR: scratch-measure-config: line {lineno}: "
                    f"expected 'key: value', got: {raw.rstrip()!r}",
                    file=sys.stderr,
                )
                sys.exit(1)
            key, _, value = line.partition(":")
            result[key.strip()] = value.strip().strip('"').strip("'")
    return result


def load_config(config_path: str) -> dict:
    """Parse the YAML config file and return a validated dict.

    Exits with a descriptive error if any required field is missing or if the
    file cannot be read.
    """
    path = Path(config_path)
    if not path.exists():
        print(
            f"ERROR: scratch-measure-config: file not found: {config_path}",
            file=sys.stderr,
        )
        sys.exit(1)

    cfg = _load_yaml(config_path)

    missing = [f for f in REQUIRED_FIELDS if not cfg.get(f)]
    if missing:
        print(
            f"ERROR: scratch-measure-config: missing required field(s): "
            f"{', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    return cfg


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------


def validate_epic_exists(epic_id: str, repo_root: str) -> None:
    """Verify the test_epic_id resolves via the ticket CLI.

    Calls `.claude/scripts/dso ticket exists <epic_id>` from *repo_root*.
    Exits non-zero with a clear error message when the epic is missing.
    """
    dso_cli = Path(repo_root) / ".claude" / "scripts" / "dso"
    if not dso_cli.exists():
        print(
            f"ERROR: scratch-measure-config: dso CLI not found at {dso_cli}",
            file=sys.stderr,
        )
        sys.exit(1)

    result = subprocess.run(
        [str(dso_cli), "ticket", "exists", epic_id],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(
            f"ERROR: scratch-measure-config: test_epic_id '{epic_id}' not found "
            f"in ticket tracker — harness cannot proceed without a valid epic id",
            file=sys.stderr,
        )
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="scratch-measure-token-reduction",
        description="Token-reduction measurement harness (config loader).",
    )
    parser.add_argument(
        "--config",
        default=str(Path(__file__).parent / "scratch-measure-config.example.yaml"),
        help="Path to YAML config file (default: example config in plugin scripts dir)",
    )
    parser.add_argument(
        "--check-config",
        action="store_true",
        help="Validate config and exit 0 if all fields resolve correctly.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    # Resolve repo root relative to this script's location so the harness
    # works from any working directory.
    # Script resolves repo_root via Path(__file__) ancestors (4 levels up).
    repo_root = str(Path(__file__).resolve().parent.parent.parent.parent)

    cfg = load_config(args.config)

    if args.check_config:
        validate_epic_exists(cfg["test_epic_id"], repo_root)
        print("scratch-measure-config: OK", flush=True)
        return 0

    # Measurement logic is added by sibling tasks.
    print(
        "ERROR: no action specified — pass --check-config or wait for "
        "sibling tasks to add measurement subcommands",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
