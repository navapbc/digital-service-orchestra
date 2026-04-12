"""
migrate_comment_refs.py — rewrite hardcoded plugins/dso/* references in comment lines.

Four comment categories handled:
  1. header:      '# plugins/dso/.../filename.ext'  →  '# filename.ext'
  2. usage:       comment lines with '.claude/scripts/dso' or 'plugins/dso/scripts/'
                  →  '${_PLUGIN_ROOT}/scripts/'
  3. path-anchor: 'See plugins/dso/docs/X.md'  →  'See ${CLAUDE_PLUGIN_ROOT}/docs/X.md'
  4. cross-ref:   inline 'plugins/dso/<subdir>/'  →  '${CLAUDE_PLUGIN_ROOT}/<subdir>/'

Only lines where the first non-whitespace characters are '#' are modified.
Rewrites are idempotent.

CLI:
  python3 migrate_comment_refs.py [--dry-run] [--verbose] <target_dir>
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import List, Tuple

# ---------------------------------------------------------------------------
# Regex patterns (applied in priority order within rewrite_comment_line)
# ---------------------------------------------------------------------------

# Category 1 – header: '# plugins/dso/<anything>/filename.ext'
# Captures the bare filename (last path component).
_RE_HEADER = re.compile(r"^(\s*#\s*)plugins/dso/[^\s]+/([^\s/]+\.[^\s/]+)$")

# Category 2a – usage with .claude/scripts/dso <script>
_RE_USAGE_DSO = re.compile(r"(\.claude/scripts/dso\s+)")

# Category 2b – usage/prose with plugins/dso/scripts/
_RE_USAGE_SCRIPTS = re.compile(r"plugins/dso/scripts/")

# Category 3 – path-anchor: plugins/dso/docs/ (kept as CLAUDE_PLUGIN_ROOT)
_RE_PATH_ANCHOR = re.compile(r"plugins/dso/docs/")

# Category 4 – cross-ref: plugins/dso/<subdir>/ for any subdir other than scripts/ or docs/
# Also catches remaining plugins/dso/<anything>/ after prior substitutions.
_RE_CROSS_REF = re.compile(r"plugins/dso/([^/\s]+)/")

# Category 5 – bare plugin root reference: 'plugins/dso' followed by non-path char
# Handles: "inside plugins/dso/", "(e.g., plugins/dso)", "at plugins/dso.", "plugins/dso →"
# Matches word boundary after 'plugins/dso' (slash, paren, period, space, comma, end-of-line)
_RE_BARE_ROOT = re.compile(r"plugins/dso(?=[/). ,\n]|$)")


def rewrite_comment_line(line: str) -> str:
    """
    Rewrite a single line according to the four comment categories.
    Lines not starting with '#' (after optional whitespace) are returned unchanged.
    Rewrites are idempotent: already-replaced placeholders pass through unchanged.

    The trailing newline (if present) is preserved in the return value.
    """
    # Strip and remember the trailing newline so all paths can restore it.
    suffix = "\n" if line.endswith("\n") else ""
    bare = line.rstrip("\n")

    # Guard: only touch comment lines
    stripped = bare.lstrip()
    if not stripped.startswith("#"):
        return line

    # ------------------------------------------------------------------
    # Category 1 – header comment: '# plugins/dso/.../filename'
    # Only replace when the ENTIRE comment body is the plugin path.
    # ------------------------------------------------------------------
    m = _RE_HEADER.match(bare)
    if m:
        prefix = m.group(1)  # e.g. '# ' or '  # '
        filename = m.group(2)  # e.g. 'foo.sh'
        return f"{prefix}{filename}{suffix}"

    # ------------------------------------------------------------------
    # Categories 2-4 – in-line substitutions (applied in sequence)
    # ------------------------------------------------------------------

    # Category 2a: .claude/scripts/dso <script> → ${_PLUGIN_ROOT}/scripts/<script>
    def _replace_dso_usage(m: re.Match) -> str:  # type: ignore[type-arg]
        # m.group(1) = ".claude/scripts/dso " (with trailing space)
        return "${_PLUGIN_ROOT}/scripts/"

    line = _RE_USAGE_DSO.sub(_replace_dso_usage, line)

    # Category 2b: plugins/dso/scripts/ → ${_PLUGIN_ROOT}/scripts/
    line = _RE_USAGE_SCRIPTS.sub("${_PLUGIN_ROOT}/scripts/", line)

    # Category 3: plugins/dso/docs/ → ${CLAUDE_PLUGIN_ROOT}/docs/
    line = _RE_PATH_ANCHOR.sub("${CLAUDE_PLUGIN_ROOT}/docs/", line)

    # Category 4: remaining plugins/dso/<subdir>/ → ${CLAUDE_PLUGIN_ROOT}/<subdir>/
    line = _RE_CROSS_REF.sub(r"${CLAUDE_PLUGIN_ROOT}/\1/", line)

    # Category 5: bare plugins/dso (followed by non-path char) → ${CLAUDE_PLUGIN_ROOT}
    line = _RE_BARE_ROOT.sub("${CLAUDE_PLUGIN_ROOT}", line)

    return line


def rewrite_file(path: Path) -> Tuple[List[str], List[str]]:
    """
    Return (original_lines, rewritten_lines).
    The caller decides whether to write the result back.
    """
    try:
        original = path.read_text(encoding="utf-8", errors="replace").splitlines(
            keepends=True
        )
    except (OSError, PermissionError):
        return [], []

    rewritten = [rewrite_comment_line(line.rstrip("\n") + "\n") for line in original]
    # Preserve the final line ending behaviour
    if original and not original[-1].endswith("\n"):
        rewritten[-1] = rewritten[-1].rstrip("\n")

    return original, rewritten


def process_directory(
    target_dir: str,
    dry_run: bool = False,
    verbose: bool = False,
) -> int:
    """
    Walk *target_dir* recursively, rewriting comment lines in all .sh files.
    Returns the number of files modified (or that would be modified in dry-run).
    """
    modified_count = 0
    root = Path(target_dir)

    for sh_file in sorted(root.rglob("*.sh")):
        if not sh_file.is_file():
            continue

        original, rewritten = rewrite_file(sh_file)
        if original == rewritten:
            continue

        modified_count += 1
        if verbose or dry_run:
            print(f"{'[dry-run] ' if dry_run else ''}Modifying: {sh_file}")
            if dry_run:
                for i, (orig, new) in enumerate(zip(original, rewritten), start=1):
                    if orig != new:
                        print(f"  line {i}: {orig.rstrip()!r}")
                        print(f"        → {new.rstrip()!r}")

        if not dry_run:
            sh_file.write_text("".join(rewritten), encoding="utf-8")

    return modified_count


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Rewrite hardcoded plugins/dso/* comment references."
    )
    parser.add_argument("target_dir", help="Directory to process recursively")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print diffs without modifying files",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print each file being modified",
    )
    args = parser.parse_args(argv)

    if not os.path.isdir(args.target_dir):
        print(f"ERROR: Not a directory: {args.target_dir}", file=sys.stderr)
        return 1

    count = process_directory(
        args.target_dir,
        dry_run=args.dry_run,
        verbose=args.verbose,
    )
    action = "Would modify" if args.dry_run else "Modified"
    print(f"{action} {count} file(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
