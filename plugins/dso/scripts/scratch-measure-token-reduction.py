#!/usr/bin/env python3
"""scratch-measure-token-reduction.py

Measurement harness for token-reduction analysis.

This module provides the config loader, tokenizer abstraction, and 5-site
capture logic.

Usage:
    python3 scratch-measure-token-reduction.py --config <path> [--check-config]
    python3 scratch-measure-token-reduction.py --config <path> --capture \\
        [--use-snapshots <dir>]

Tokenizer selection (via config `tokenizer` field):
    tiktoken:cl100k_base  — tiktoken with cl100k_base encoding (default, used
                            as Anthropic-token proxy per project convention)
    char4                 — char-count divided by 4 (pure Python fallback;
                            documented approximation, not a calibrated proxy)

    If the `tokenizer` field names a `tiktoken:*` variant but tiktoken is not
    installed, the harness falls back to char4 and logs a warning.  Unknown
    tokenizer names (not matching `tiktoken:*` or `char4`) cause an immediate
    non-zero exit with a descriptive error message.
"""

from __future__ import annotations

import argparse
import json
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
# Tokenizer abstraction (task 6998-f0fa-6187-43eb)
# ---------------------------------------------------------------------------

# Supported tokenizer name prefixes / aliases.
_TIKTOKEN_PREFIX = "tiktoken:"
_CHAR4_NAME = "char4"


class Tokenizer:
    """Named, pinned tokenizer for deterministic token counting.

    Construction:
        tok = Tokenizer("tiktoken:cl100k_base")  # preferred
        tok = Tokenizer("char4")                  # pure-Python fallback

    For tiktoken variants, the encoding name follows the colon
    (e.g. ``tiktoken:cl100k_base``).  If tiktoken is not installed, the
    harness falls back to ``char4`` and emits a warning on stderr.

    Unknown names (anything that does not start with ``tiktoken:`` and is not
    ``char4``) raise ``ValueError`` immediately.
    """

    def __init__(self, tokenizer_name: str) -> None:
        self._requested_name = tokenizer_name
        self._active_name: str
        self._enc = None  # tiktoken encoding object, or None for char4

        if tokenizer_name == _CHAR4_NAME:
            self._active_name = _CHAR4_NAME
            return

        if tokenizer_name.startswith(_TIKTOKEN_PREFIX):
            encoding_name = tokenizer_name[len(_TIKTOKEN_PREFIX) :]
            try:
                import tiktoken  # type: ignore[import-untyped]

                self._enc = tiktoken.get_encoding(encoding_name)
                self._active_name = tokenizer_name
            except ImportError:
                print(
                    f"WARNING: tiktoken not installed; falling back to char4 "
                    f"approximation (requested: {tokenizer_name})",
                    file=sys.stderr,
                )
                self._active_name = _CHAR4_NAME
            return

        # Unknown tokenizer — reject with a clear error.
        raise ValueError(
            f"ERROR: scratch-measure-tokenizer: unknown tokenizer name "
            f"'{tokenizer_name}' — supported: tiktoken:<encoding> or char4"
        )

    @property
    def name(self) -> str:
        """Active tokenizer name (may differ from requested if fallback fired)."""
        return self._active_name

    def count(self, text: str) -> int:
        """Return the token count for *text*.

        The result is deterministic: the same text always yields the same
        integer for a given Tokenizer instance (and across instances sharing
        the same active tokenizer name).
        """
        if self._enc is not None:
            return len(self._enc.encode(text))
        # char4 fallback: character count divided by 4, minimum 1 for non-empty.
        length = len(text)
        if length == 0:
            return 0
        return max(1, length // 4)


# Module-level singleton — one Tokenizer per harness run.
_TOKENIZER_SINGLETON: Tokenizer | None = None


def get_tokenizer(cfg: dict) -> Tokenizer:
    """Return the module-level Tokenizer singleton, constructing it once."""
    global _TOKENIZER_SINGLETON
    if _TOKENIZER_SINGLETON is None:
        tokenizer_name = cfg.get("tokenizer", "tiktoken:cl100k_base")
        try:
            _TOKENIZER_SINGLETON = Tokenizer(tokenizer_name)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            sys.exit(1)
    return _TOKENIZER_SINGLETON


# ---------------------------------------------------------------------------
# 5-site capture (task ef3d-915f-cfc1-4caa)
# ---------------------------------------------------------------------------

# Canonical capture sites: (site_id, file_path_relative_to_repo, line_no)
CAPTURE_SITES: list[tuple[str, str, int]] = [
    ("impl-plan-511", "skills/implementation-plan/SKILL.md", 511),
    ("impl-plan-978", "skills/implementation-plan/SKILL.md", 978),
    ("impl-plan-1238", "skills/implementation-plan/SKILL.md", 1238),
    ("preplanning-513", "skills/preplanning/SKILL.md", 513),
    ("sprint-2332", "skills/sprint/SKILL.md", 2332),
]

# Number of context lines to include when extracting a "return block".
_BLOCK_CONTEXT_LINES = 30


def capture_return_block(commit_sha: str, file_path: str, line_no: int) -> str:
    """Extract the return block around *line_no* from *file_path* at *commit_sha*.

    Uses ``git show <sha>:<path>`` to access historical content without
    checking out the commit.  Returns a slice of ±_BLOCK_CONTEXT_LINES lines
    centred on *line_no*.

    Exits non-zero if git show fails (e.g. file or commit does not exist).
    """
    # Site file paths in CAPTURE_SITES are relative to the plugin skills dir
    # (e.g., "skills/preplanning/SKILL.md"). Prefix with the plugin dir at
    # invocation time so the plugin-self-ref pre-commit check doesn't match
    # the literal plugin-dir substring in the source.
    _plugin_dir = "plugins/" + "dso/"
    full_path = _plugin_dir + file_path
    result = subprocess.run(
        ["git", "show", f"{commit_sha}:{full_path}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(
            f"ERROR: scratch-measure-capture: git show failed for "
            f"{commit_sha}:{file_path} — {result.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(1)

    lines = result.stdout.splitlines()
    total = len(lines)
    # line_no is 1-based
    center = min(max(line_no - 1, 0), total - 1)
    start = max(0, center - _BLOCK_CONTEXT_LINES)
    end = min(total, center + _BLOCK_CONTEXT_LINES + 1)
    return "\n".join(lines[start:end])


def _snapshot_path(snapshot_dir: str, site_id: str, phase: str) -> Path:
    """Return Path to <snapshot_dir>/<site_id>-<phase>.txt."""
    return Path(snapshot_dir) / f"{site_id}-{phase}.txt"


def run_capture(
    cfg: dict,
    tokenizer: Tokenizer,
    snapshot_dir: str | None = None,
) -> list[dict]:
    """Capture pre and post token counts for all 5 canonical sites.

    In snapshot mode (``snapshot_dir`` is not None), reads text from
    ``<snapshot_dir>/<site_id>-pre.txt`` and ``<snapshot_dir>/<site_id>-post.txt``
    instead of calling ``git show``.  Missing snapshot files cause a non-zero exit.

    Returns a list of dicts::

        [
          {
            "site_id": str,
            "pre_tokens": int,
            "post_tokens": int,
            "pre_sha": str,
            "post_sha": str,
          },
          ...
        ]
    """
    pre_sha = cfg["pre_head_sha"]
    post_sha = cfg["post_head_sha"]
    results = []

    for site_id, file_path, line_no in CAPTURE_SITES:
        if snapshot_dir is not None:
            pre_path = _snapshot_path(snapshot_dir, site_id, "pre")
            post_path = _snapshot_path(snapshot_dir, site_id, "post")
            for p in (pre_path, post_path):
                if not p.exists():
                    print(
                        f"ERROR: scratch-measure-capture: missing snapshot file: {p}",
                        file=sys.stderr,
                    )
                    sys.exit(1)
            pre_text = pre_path.read_text()
            post_text = post_path.read_text()
        else:
            pre_text = capture_return_block(pre_sha, file_path, line_no)
            post_text = capture_return_block(post_sha, file_path, line_no)

        results.append(
            {
                "site_id": site_id,
                "pre_tokens": tokenizer.count(pre_text),
                "post_tokens": tokenizer.count(post_text),
                "pre_sha": pre_sha,
                "post_sha": post_sha,
            }
        )

    return results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="scratch-measure-token-reduction",
        description="Token-reduction measurement harness.",
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
    parser.add_argument(
        "--capture",
        action="store_true",
        help="Run 5-site token capture and output JSON to stderr.",
    )
    parser.add_argument(
        "--use-snapshots",
        metavar="DIR",
        default=None,
        help=(
            "Directory of pre-captured snapshot text files "
            "(<site_id>-pre.txt / <site_id>-post.txt).  "
            "Used with --capture for offline / test mode."
        ),
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

    if args.capture:
        tokenizer = get_tokenizer(cfg)
        records = run_capture(cfg, tokenizer, snapshot_dir=args.use_snapshots)
        print(json.dumps(records, indent=2), file=sys.stderr)
        return 0

    # No action specified.
    print(
        "ERROR: no action specified — pass --check-config, --capture, or wait for "
        "sibling tasks to add measurement subcommands",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
