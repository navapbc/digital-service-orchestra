#!/usr/bin/env python3
"""Migrate plugins/dso/ references in markdown files to portable alternatives.

Runtime paths (in code blocks, tool invocations) → ${CLAUDE_PLUGIN_ROOT}/path
Prose references (backtick paths in text, headings, etc.) → strip plugins/dso/ prefix

Usage:
    python3 scripts/migrate-markdown-refs.py [--dry-run] [--verbose] [--runtime-only] <target_dirs...>
"""

from __future__ import annotations

import argparse
import os
import re
import sys


# Pattern to match plugins/dso/ references
PLUGINS_DSO_RE = re.compile(r"plugins/dso/")

# Lines that are clearly runtime/code context
RUNTIME_LINE_PATTERNS = [
    re.compile(r"^\s*```"),  # fenced code block delimiter
    re.compile(r"^\s*source\s+"),  # shell source command
    re.compile(r"^\s*bash\s+"),  # bash invocation
    re.compile(r"^\s*sh\s+"),  # sh invocation
    re.compile(r"^\s*python3?\s+"),  # python invocation
    re.compile(r"^\s*cat\s+"),  # cat command
    re.compile(r"^\s*grep\s+"),  # grep command
    re.compile(r"^\s*echo\s+"),  # echo command
    re.compile(r"Read\("),  # Tool invocation
    re.compile(r"Glob\("),  # Tool invocation
    re.compile(r"Grep\("),  # Tool invocation
    re.compile(r"Bash\("),  # Tool invocation
]

# Already using CLAUDE_PLUGIN_ROOT — skip
ALREADY_PORTABLE_RE = re.compile(r"\$\{?CLAUDE_PLUGIN_ROOT\}?")

# Pattern for backtick-wrapped paths in prose
BACKTICK_PATH_RE = re.compile(r"`([^`]*plugins/dso/[^`]*)`")


def is_runtime_line(line: str) -> bool:
    """Check if a line is in runtime/code context."""
    for pattern in RUNTIME_LINE_PATTERNS:
        if pattern.search(line):
            return True
    # Table cells with commands: | ... `bash ...` or | ... `cat ...`
    if re.search(r"\|\s*`(bash|sh|cat|source|python3?|grep)\s+", line):
        return True
    return False


def classify_and_convert(line: str, in_code_block: bool) -> tuple[str, str | None]:
    """Classify a line and convert plugins/dso/ references.

    Returns (converted_line, conversion_type) where conversion_type is
    'runtime', 'prose', or None if no conversion needed.
    """
    if not PLUGINS_DSO_RE.search(line):
        return line, None

    # Skip lines that already use CLAUDE_PLUGIN_ROOT
    if ALREADY_PORTABLE_RE.search(line):
        # But still convert any remaining plugins/dso/ refs on the same line
        # that aren't part of the CLAUDE_PLUGIN_ROOT pattern
        # e.g., ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}
        # Check if all plugins/dso/ refs are inside a fallback pattern
        test_line = re.sub(
            r"\$\{CLAUDE_PLUGIN_ROOT:-\$REPO_ROOT/plugins/dso\}", "", line
        )
        test_line = re.sub(r"\$CLAUDE_PLUGIN_ROOT/\S*", "", test_line)
        if not PLUGINS_DSO_RE.search(test_line):
            return line, None

    if in_code_block or is_runtime_line(line):
        return _convert_runtime(line), "runtime"
    else:
        return _convert_prose(line), "prose"


def _convert_runtime(line: str) -> str:
    """Convert runtime references to ${CLAUDE_PLUGIN_ROOT}/path.

    Handles:
    - $REPO_ROOT/plugins/dso/path → ${CLAUDE_PLUGIN_ROOT}/path
    - "$REPO_ROOT/plugins/dso/path" → "${CLAUDE_PLUGIN_ROOT}/path"
    - plugins/dso/path → ${CLAUDE_PLUGIN_ROOT}/path
    """
    # First: $REPO_ROOT/plugins/dso/ → ${CLAUDE_PLUGIN_ROOT}/
    line = re.sub(r"\$\{?REPO_ROOT\}?/plugins/dso/", "${CLAUDE_PLUGIN_ROOT}/", line)
    # Then: remaining bare plugins/dso/ → ${CLAUDE_PLUGIN_ROOT}/
    # But skip if inside a fallback like ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}
    line = re.sub(r"(?<!\:-\$REPO_ROOT/)plugins/dso/", "${CLAUDE_PLUGIN_ROOT}/", line)
    return line


def _convert_prose(line: str) -> str:
    """Convert prose references by stripping the plugins/dso/ prefix.

    Handles:
    - `plugins/dso/path/file.md` → `path/file.md`
    - plugins/dso/path in plain text → path
    - ### Heading (`plugins/dso/path/`) → ### Heading (`path/`)
    - `plugins/dso/` (bare directory) → `the plugin root`
    - Backtick-wrapped commands (bash, cat, source, Read, etc.) → runtime conversion
    """

    # Handle backtick-wrapped paths first
    def replace_backtick_path(m: re.Match) -> str:
        inner = m.group(1)
        # If the backtick content looks like a command, use runtime conversion
        if re.match(r"(bash|sh|cat|source|python3?|grep|echo)\s+", inner):
            inner = re.sub(
                r"\$\{?REPO_ROOT\}?/plugins/dso/", "${CLAUDE_PLUGIN_ROOT}/", inner
            )
            inner = re.sub(
                r"(?<!\:-\$REPO_ROOT/)plugins/dso/", "${CLAUDE_PLUGIN_ROOT}/", inner
            )
            return f"`{inner}`"
        inner = re.sub(r"\$\{?REPO_ROOT\}?/plugins/dso/", "", inner)
        # Handle bare `plugins/dso/` → keep as descriptive text
        if inner == "plugins/dso/" or inner == "plugins/dso":
            return "the plugin root directory"
        inner = inner.replace("plugins/dso/", "")
        return f"`{inner}`"

    line = BACKTICK_PATH_RE.sub(replace_backtick_path, line)

    # Handle remaining bare references not in backticks
    # $REPO_ROOT/plugins/dso/ → strip entirely
    line = re.sub(r"\$\{?REPO_ROOT\}?/plugins/dso/", "", line)
    # Bare plugins/dso/ → strip (but keep it if it would leave nothing meaningful)
    line = line.replace("plugins/dso/", "")

    return line


def process_file(
    filepath: str,
    dry_run: bool = False,
    verbose: bool = False,
    runtime_only: bool = False,
) -> dict:
    """Process a single markdown file.

    Returns stats dict with runtime_count, prose_count, skipped_count.
    """
    stats = {"runtime": 0, "prose": 0, "skipped": 0, "changes": []}

    with open(filepath, "r", encoding="utf-8") as f:
        original_lines = f.readlines()

    new_lines = []
    in_code_block = False

    for i, line in enumerate(original_lines, 1):
        stripped = line.rstrip("\n")

        # Track code block state
        if re.match(r"\s*```", stripped):
            # Toggle code block state (only if it's a fence, not inline)
            # Opening fence: ``` or ```language
            # Closing fence: ```
            if in_code_block:
                # This is a closing fence — process this line as still in code block
                converted, conv_type = classify_and_convert(stripped, True)
                in_code_block = False
            else:
                # This is an opening fence — process this line as not yet in code block
                converted, conv_type = classify_and_convert(stripped, False)
                in_code_block = True
        else:
            converted, conv_type = classify_and_convert(stripped, in_code_block)

        if conv_type == "runtime":
            stats["runtime"] += 1
            if verbose:
                stats["changes"].append(
                    f"  {filepath}:{i} [runtime]\n    - {stripped}\n    + {converted}"
                )
        elif conv_type == "prose":
            if runtime_only:
                stats["skipped"] += 1
                converted = stripped  # Don't apply prose conversion
            else:
                stats["prose"] += 1
                if verbose:
                    stats["changes"].append(
                        f"  {filepath}:{i} [prose]\n    - {stripped}\n    + {converted}"
                    )

        new_lines.append(converted + "\n")

    if not dry_run and (stats["runtime"] > 0 or stats["prose"] > 0):
        with open(filepath, "w", encoding="utf-8") as f:
            f.writelines(new_lines)

    return stats


def find_md_files(directories: list[str]) -> list[str]:
    """Find all .md files in given directories."""
    md_files = []
    for directory in directories:
        for root, _dirs, files in os.walk(directory):
            for fname in sorted(files):
                if fname.endswith(".md"):
                    md_files.append(os.path.join(root, fname))
    return sorted(md_files)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Migrate plugins/dso/ references in markdown files"
    )
    parser.add_argument("directories", nargs="+", help="Directories to scan")
    parser.add_argument(
        "--dry-run", action="store_true", help="Show changes without applying"
    )
    parser.add_argument("--verbose", action="store_true", help="Show detailed changes")
    parser.add_argument(
        "--runtime-only", action="store_true", help="Only convert runtime references"
    )

    args = parser.parse_args()

    # Validate directories exist
    for d in args.directories:
        if not os.path.isdir(d):
            print(f"Error: {d} is not a directory", file=sys.stderr)
            return 1

    md_files = find_md_files(args.directories)

    total_runtime = 0
    total_prose = 0
    total_skipped = 0
    files_modified = 0

    for filepath in md_files:
        stats = process_file(
            filepath,
            dry_run=args.dry_run,
            verbose=args.verbose,
            runtime_only=args.runtime_only,
        )

        if stats["runtime"] > 0 or stats["prose"] > 0:
            files_modified += 1
            if args.verbose:
                for change in stats["changes"]:
                    print(change)

        total_runtime += stats["runtime"]
        total_prose += stats["prose"]
        total_skipped += stats["skipped"]

    mode = "DRY RUN" if args.dry_run else "APPLIED"
    scope = "runtime-only" if args.runtime_only else "full"
    print(f"\n{mode} ({scope}):")
    print(f"  Files scanned: {len(md_files)}")
    print(f"  Files modified: {files_modified}")
    print(f"  Runtime conversions: {total_runtime}")
    print(f"  Prose conversions: {total_prose}")
    if total_skipped:
        print(f"  Prose skipped (runtime-only mode): {total_skipped}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
