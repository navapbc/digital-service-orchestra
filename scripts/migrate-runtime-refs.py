#!/usr/bin/env python3
"""Migrate plugins/dso references in .sh files to portable _PLUGIN_ROOT alternatives.

Operations:
  1. inject        – Insert _PLUGIN_ROOT declaration into .sh files that lack it
  2. replace_variable_anchored – Replace $REPO_ROOT/plugins/dso/ etc. with ${_PLUGIN_ROOT}/
  3. derive_and_replace_git_relative – Add _PLUGIN_GIT_PATH derivation and replace bare refs
  4. replace_user_messages – Replace plugins/dso in echo/printf/>&2 lines
  5. update_config  – Rewrite config file comments and JSON examples

Usage:
    python3 scripts/migrate-runtime-refs.py [--dry-run] [--verbose] <target_dir>
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PLUGIN_ROOT_DECL = '_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"'

PLUGIN_GIT_PATH_DECL = (
    '_PLUGIN_GIT_PATH="${_PLUGIN_ROOT#$(git rev-parse --show-toplevel)/}"'
)

# Patterns for variable-anchored references (operation 2)
_VAR_ANCHORED_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso} → ${_PLUGIN_ROOT}
    (
        re.compile(r"\$\{CLAUDE_PLUGIN_ROOT:-\$REPO_ROOT/plugins/dso\}"),
        "${_PLUGIN_ROOT}",
    ),
    # ${CLAUDE_PLUGIN_ROOT:-$_root/plugins/dso} → ${_PLUGIN_ROOT}
    (
        re.compile(r"\$\{CLAUDE_PLUGIN_ROOT:-\$_root/plugins/dso\}"),
        "${_PLUGIN_ROOT}",
    ),
    # $REPO_ROOT/plugins/dso/ → ${_PLUGIN_ROOT}/
    (
        re.compile(r"\$REPO_ROOT/plugins/dso/"),
        "${_PLUGIN_ROOT}/",
    ),
    # $_root/plugins/dso/ → ${_PLUGIN_ROOT}/
    (
        re.compile(r"\$_root/plugins/dso/"),
        "${_PLUGIN_ROOT}/",
    ),
    # $DIST_ROOT/plugins/dso/ → ${_PLUGIN_ROOT}/
    (
        re.compile(r"\$DIST_ROOT/plugins/dso/"),
        "${_PLUGIN_ROOT}/",
    ),
    # ${REPO_ROOT}/plugins/dso/ → ${_PLUGIN_ROOT}/
    (
        re.compile(r"\$\{REPO_ROOT\}/plugins/dso/"),
        "${_PLUGIN_ROOT}/",
    ),
    # ${_root}/plugins/dso/ → ${_PLUGIN_ROOT}/
    (
        re.compile(r"\$\{_root\}/plugins/dso/"),
        "${_PLUGIN_ROOT}/",
    ),
    # ${DIST_ROOT}/plugins/dso/ → ${_PLUGIN_ROOT}/
    (
        re.compile(r"\$\{DIST_ROOT\}/plugins/dso/"),
        "${_PLUGIN_ROOT}/",
    ),
]

# Glob pattern: */plugins/dso/* → */${_PLUGIN_GIT_PATH}/*
_GLOB_PATTERN = re.compile(r"\*/plugins/dso/\*")
_GLOB_REPLACEMENT = "*/${_PLUGIN_GIT_PATH}/*"

# Patterns that indicate git-relative usage (operation 3)
_GIT_RELATIVE_INDICATORS = [
    "git show",
    "git diff",
    "git log",
]

# Bare plugins/dso/ reference (not already wrapped in ${...})
_BARE_PLUGINS_DSO = re.compile(
    r"(?<!\$\{_PLUGIN_ROOT\}/)(?<!\$\{_PLUGIN_GIT_PATH\}/)plugins/dso/"
)


def _is_comment_line(line: str) -> bool:
    """Return True if line is a shell comment (stripped starts with #)."""
    return line.lstrip().startswith("#")


def _is_shebang(line: str) -> bool:
    """Return True if line is a shebang line."""
    return line.startswith("#!")


def _is_set_options(line: str) -> bool:
    """Return True if line is set -e / set -euo pipefail / set -eu etc."""
    stripped = line.strip()
    return bool(re.match(r"^set\s+-[a-z]+", stripped))


def _has_plugin_root_decl(lines: list[str]) -> bool:
    """Return True if any line already contains _PLUGIN_ROOT=."""
    for line in lines:
        if "_PLUGIN_ROOT=" in line and not _is_comment_line(line):
            return True
    return False


def _has_git_path_decl(lines: list[str]) -> bool:
    """Return True if any line already contains _PLUGIN_GIT_PATH=."""
    for line in lines:
        if "_PLUGIN_GIT_PATH=" in line and not _is_comment_line(line):
            return True
    return False


def _has_plugins_dso_code_ref(lines: list[str]) -> bool:
    """Return True if any non-comment code line references plugins/dso."""
    for line in lines:
        if not _is_comment_line(line) and "plugins/dso" in line:
            return True
    return False


def _needs_git_path(line: str) -> bool:
    """Check if a non-comment line uses bare plugins/dso/ in a git-relative context."""
    stripped = line.strip()
    # Case pattern: case ... in plugins/dso/...) or plugins/dso/...|...)
    if "plugins/dso/" in stripped and ("case " in stripped or ")" in stripped):
        return True
    # Git commands
    for indicator in _GIT_RELATIVE_INDICATORS:
        if indicator in stripped and "plugins/dso/" in stripped:
            return True
    # grep patterns with bare plugins/dso/
    if re.search(r"grep\b.*plugins/dso/", stripped):
        return True
    return False


# ---------------------------------------------------------------------------
# Public API: per-file migration functions
# ---------------------------------------------------------------------------


def inject_plugin_root(lines: list[str]) -> list[str]:
    """Operation 1: Insert _PLUGIN_ROOT declaration after shebang/set line.

    If the file already has _PLUGIN_ROOT=, return lines unchanged.
    Only injects if there are plugins/dso references in non-comment code lines.
    """
    if _has_plugin_root_decl(lines):
        return list(lines)
    if not _has_plugins_dso_code_ref(lines):
        return list(lines)

    result = list(lines)
    insert_idx = 1  # default: after first line (shebang)

    if len(result) > 0 and _is_shebang(result[0]):
        # Check if line 2 is set -e/set -euo pipefail
        if len(result) > 1 and _is_set_options(result[1]):
            insert_idx = 2
        else:
            insert_idx = 1
    else:
        insert_idx = 0

    result.insert(insert_idx, PLUGIN_ROOT_DECL + "\n")
    return result


def replace_variable_refs(lines: list[str]) -> list[str]:
    """Operation 2: Replace variable-anchored plugins/dso references."""
    result = []
    for line in lines:
        if _is_comment_line(line):
            result.append(line)
            continue
        new_line = line
        for pattern, replacement in _VAR_ANCHORED_PATTERNS:
            new_line = pattern.sub(replacement, new_line)
        # Glob patterns
        new_line = _GLOB_PATTERN.sub(_GLOB_REPLACEMENT, new_line)
        result.append(new_line)
    return result


def derive_plugin_git_path_needed(lines: list[str]) -> bool:
    """Check if any non-comment line needs _PLUGIN_GIT_PATH derivation.

    Returns True if there are bare plugins/dso/ references in git-relative
    contexts (git show, git diff, case patterns, grep patterns).
    """
    for line in lines:
        if _is_comment_line(line):
            continue
        if _needs_git_path(line):
            return True
    return False


def replace_git_relative_refs(lines: list[str]) -> list[str]:
    """Operation 3: Add _PLUGIN_GIT_PATH derivation and replace bare refs.

    Inserts _PLUGIN_GIT_PATH declaration after _PLUGIN_ROOT if not present,
    then replaces bare plugins/dso/ in git-relative contexts.
    """
    needs_derivation = derive_plugin_git_path_needed(lines)
    if not needs_derivation:
        return list(lines)

    result = list(lines)

    # Insert _PLUGIN_GIT_PATH after _PLUGIN_ROOT if not already present
    if not _has_git_path_decl(result):
        insert_idx = None
        for i, line in enumerate(result):
            if "_PLUGIN_ROOT=" in line and not _is_comment_line(line):
                insert_idx = i + 1
                break
        if insert_idx is not None:
            result.insert(insert_idx, PLUGIN_GIT_PATH_DECL + "\n")

    # Replace bare plugins/dso/ in git-relative contexts
    final = []
    for line in result:
        if _is_comment_line(line):
            final.append(line)
            continue
        if _needs_git_path(line):
            new_line = line.replace("plugins/dso/", "${_PLUGIN_GIT_PATH}/")
            final.append(new_line)
        else:
            final.append(line)
    return final


def replace_user_message_refs(lines: list[str]) -> list[str]:
    """Operation 4: Replace plugins/dso in echo/printf/>&2 lines."""
    result = []
    msg_pattern = re.compile(r"^\s*(echo|printf)\b|>&2")
    for line in lines:
        if _is_comment_line(line):
            result.append(line)
            continue
        if msg_pattern.search(line) and "plugins/dso" in line:
            new_line = line.replace("plugins/dso/", "${_PLUGIN_ROOT}/")
            # Handle bare plugins/dso (no trailing slash)
            new_line = new_line.replace("plugins/dso", "${_PLUGIN_ROOT}")
            result.append(new_line)
        else:
            result.append(line)
    return result


def migrate_file(filepath: str, dry_run: bool = False, verbose: bool = False) -> bool:
    """Apply all migration operations to a single .sh file.

    Returns True if the file was (or would be) modified.
    """
    path = Path(filepath)
    if not path.exists():
        return False

    original = path.read_text()
    lines = original.splitlines(keepends=True)

    # Ensure lines have trailing newlines for consistency
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    # Apply operations in order
    lines = inject_plugin_root(lines)
    lines = replace_variable_refs(lines)
    lines = replace_git_relative_refs(lines)
    lines = replace_user_message_refs(lines)

    new_content = "".join(lines)
    changed = new_content != original

    if changed:
        if verbose:
            action = "would modify" if dry_run else "modified"
            print(f"  {action}: {filepath}")
        if not dry_run:
            path.write_text(new_content)

    return changed


def update_config_files(
    target_dir: str, dry_run: bool = False, verbose: bool = False
) -> int:
    """Operation 5: Update config files with generic path references.

    Returns number of files modified.
    """
    count = 0
    target = Path(target_dir)

    # 5a: plugin-boundary-allowlist.conf – rewrite comment lines referencing plugins/dso/
    allowlist = target / "hooks" / "pre-commit" / "plugin-boundary-allowlist.conf"
    if allowlist.exists():
        original = allowlist.read_text()
        lines = original.splitlines(keepends=True)
        new_lines = []
        for line in lines:
            if _is_comment_line(line) and "plugins/dso/" in line:
                new_line = line.replace("plugins/dso/", "the plugin root directory/")
                new_lines.append(new_line)
            else:
                new_lines.append(line)
        new_content = "".join(new_lines)
        if new_content != original:
            count += 1
            if verbose:
                action = "would modify" if dry_run else "modified"
                print(f"  {action}: {allowlist}")
            if not dry_run:
                allowlist.write_text(new_content)

    # 5b: workflow-config-schema.json – replace example with generic path
    schema = target / "docs" / "workflow-config-schema.json"
    if schema.exists():
        original = schema.read_text()
        new_content = original.replace(
            '"plugins/dso/skills/**;plugins/dso/hooks/**;CLAUDE.md"',
            '"skills/**;hooks/**;CLAUDE.md"',
        )
        if new_content != original:
            count += 1
            if verbose:
                action = "would modify" if dry_run else "modified"
                print(f"  {action}: {schema}")
            if not dry_run:
                schema.write_text(new_content)

    return count


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description="Migrate plugins/dso references to portable alternatives"
    )
    parser.add_argument("target_dir", help="Directory to scan for .sh files")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without modifying files",
    )
    parser.add_argument(
        "--verbose", action="store_true", help="Print each modified file"
    )
    args = parser.parse_args(argv)

    target = Path(args.target_dir)
    if not target.is_dir():
        print(f"Error: {args.target_dir} is not a directory", file=sys.stderr)
        return 1

    modified_count = 0

    # Scan for .sh files
    for sh_file in sorted(target.rglob("*.sh")):
        if migrate_file(str(sh_file), dry_run=args.dry_run, verbose=args.verbose):
            modified_count += 1

    # Update config files
    config_count = update_config_files(
        str(target), dry_run=args.dry_run, verbose=args.verbose
    )
    modified_count += config_count

    action = "Would modify" if args.dry_run else "Modified"
    print(f"{action} {modified_count} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
