#!/usr/bin/env python3
"""Migrate plugins/dso references in Markdown files to portable alternatives.

Classification:
  Runtime context (inside code blocks, tool calls, shell invocations)
    -> ${CLAUDE_PLUGIN_ROOT}/path
  Prose context (backtick paths, plain text in flowing prose)
    -> strip plugins/dso/ prefix

CLI:
  python3 scripts/migrate-markdown-refs.py [--dry-run] [--verbose] [--runtime-only] <target_dirs...>
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Pattern matching plugins/dso references
_PLUGINS_DSO_RE = re.compile(r"plugins/dso/")

# Patterns that indicate runtime context on a single line
_RUNTIME_LINE_PATTERNS = [
    re.compile(r"Read\(.*plugins/dso/"),
    re.compile(r"Glob\(.*plugins/dso/"),
    re.compile(r"Grep\(.*plugins/dso/"),
    re.compile(r"Bash\(.*plugins/dso/"),
    re.compile(r"^cat\s"),
    re.compile(r"^source\s"),
    re.compile(r"^bash\s"),
    re.compile(r"^sh\s"),
    re.compile(r"\.claude/scripts/dso"),
]

# Fenced code block opener: ``` optionally followed by a language identifier
_FENCE_OPEN_RE = re.compile(r"^```")
_FENCE_CLOSE_RE = re.compile(r"^```\s*$")


def _is_runtime_line(line: str) -> bool:
    """Check if a line has runtime context indicators (outside code blocks)."""
    stripped = line.strip()
    for pat in _RUNTIME_LINE_PATTERNS:
        if pat.search(stripped):
            return True
    return False


def _replace_runtime(line: str) -> str:
    """Replace plugins/dso/ with ${CLAUDE_PLUGIN_ROOT}/ for runtime context."""
    return line.replace("plugins/dso/", "${CLAUDE_PLUGIN_ROOT}/")


def _replace_prose(line: str) -> str:
    """Strip plugins/dso/ prefix for prose context."""
    return line.replace("plugins/dso/", "")


def migrate_file(
    path: str | Path,
    dry_run: bool = False,
    runtime_only: bool = False,
    verbose: bool = False,
) -> dict:
    """Migrate plugins/dso references in a single file.

    Args:
        path: Path to the markdown file.
        dry_run: If True, don't write changes.
        runtime_only: If True, only convert runtime refs, skip prose.
        verbose: If True, print detailed output.

    Returns:
        dict with keys: path, runtime_count, prose_count, skipped_count, changed
    """
    path = Path(path)
    result = {
        "path": str(path),
        "runtime_count": 0,
        "prose_count": 0,
        "skipped_count": 0,
        "changed": False,
    }

    if not path.exists():
        return result

    original_lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    new_lines: list[str] = []
    in_code_block = False

    for line in original_lines:
        stripped = line.strip()

        # Track fenced code block state
        if not in_code_block and _FENCE_OPEN_RE.match(stripped) and stripped != "```":
            # Opening fence with language identifier (```bash, ```json, etc.)
            in_code_block = True
            new_lines.append(line)
            continue
        elif not in_code_block and stripped == "```":
            # Bare ``` — opening fence
            in_code_block = True
            new_lines.append(line)
            continue
        elif in_code_block and _FENCE_CLOSE_RE.match(stripped):
            # Closing fence
            in_code_block = False
            new_lines.append(line)
            continue

        # Check if line contains plugins/dso references
        if "plugins/dso/" not in line:
            new_lines.append(line)
            continue

        # Skip lines with # shim-exempt:
        if "# shim-exempt:" in line:
            result["skipped_count"] += 1
            new_lines.append(line)
            continue

        # Classify and transform
        if in_code_block or _is_runtime_line(line):
            # Runtime context
            new_line = _replace_runtime(line)
            result["runtime_count"] += line.count("plugins/dso/")
            if verbose:
                print(f"  RUNTIME: {line.rstrip()}")
            new_lines.append(new_line)
        elif runtime_only:
            # Prose but --runtime-only mode, skip
            result["skipped_count"] += 1
            new_lines.append(line)
        else:
            # Prose context
            new_line = _replace_prose(line)
            result["prose_count"] += line.count("plugins/dso/")
            if verbose:
                print(f"  PROSE: {line.rstrip()}")
            new_lines.append(new_line)

    new_content = "".join(new_lines)
    original_content = "".join(original_lines)

    if new_content != original_content:
        result["changed"] = True
        if not dry_run:
            path.write_text(new_content, encoding="utf-8")

    return result


def migrate_directory(
    target_dir: str | Path,
    dry_run: bool = False,
    runtime_only: bool = False,
    verbose: bool = False,
) -> list[dict]:
    """Migrate all .md files in a directory tree."""
    target = Path(target_dir)
    results = []
    for md_file in sorted(target.rglob("*.md")):
        result = migrate_file(
            md_file, dry_run=dry_run, runtime_only=runtime_only, verbose=verbose
        )
        results.append(result)
        if verbose and result["changed"]:
            print(
                f"  {result['path']}: {result['runtime_count']} runtime, {result['prose_count']} prose"
            )
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Migrate plugins/dso references in Markdown files."
    )
    parser.add_argument("target_dirs", nargs="+", help="Directories to scan")
    parser.add_argument("--dry-run", action="store_true", help="Don't write changes")
    parser.add_argument("--verbose", action="store_true", help="Print detailed output")
    parser.add_argument(
        "--runtime-only",
        action="store_true",
        help="Only convert runtime refs; skip prose stripping",
    )
    args = parser.parse_args(argv)

    total_runtime = 0
    total_prose = 0
    total_skipped = 0
    total_changed = 0

    for target_dir in args.target_dirs:
        results = migrate_directory(
            target_dir,
            dry_run=args.dry_run,
            runtime_only=args.runtime_only,
            verbose=args.verbose,
        )
        for r in results:
            total_runtime += r["runtime_count"]
            total_prose += r["prose_count"]
            total_skipped += r["skipped_count"]
            if r["changed"]:
                total_changed += 1

    prefix = "[DRY RUN] " if args.dry_run else ""
    print(
        f"{prefix}{total_changed} files changed, "
        f"{total_runtime} runtime refs, "
        f"{total_prose} prose refs, "
        f"{total_skipped} skipped"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
