#!/usr/bin/env python3
"""Static analysis: detect file-write operations in hook scripts that target disallowed paths.

Hook scripts must only write to sanctioned directories (artifacts dir, /tmp/, ~/.claude/).
Writes to repository files, config files, or user-visible paths are violations.

Detection strategy (hybrid):
  1. Primary: bashlex AST analysis — walks parsed nodes for RedirectNode (>, >>)
     and write commands (tee, cp, mv, touch, mkdir).
  2. Fallback: regex-based detection for lines that bashlex cannot parse
     (e.g., [[ ]], case statements, complex bash-isms).

The allowlist applies identically regardless of detection method.

Usage:
    python3 lockpick-workflow/scripts/check-hook-file-writes.py [--verbose] [--json]
    python3 lockpick-workflow/scripts/check-hook-file-writes.py --check <file>  # single file

Exit codes:
    0 — no violations found
    1 — violations found
    2 — usage error
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    import bashlex
    import bashlex.errors

    HAS_BASHLEX = True
except ImportError:
    HAS_BASHLEX = False


# ---------------------------------------------------------------------------
# Allowlisted write-target patterns (variable names and path prefixes)
# ---------------------------------------------------------------------------

# Variables whose expansion resolves to sanctioned directories.
# Any write whose target starts with one of these variables is allowed.
ALLOWED_VARIABLES: frozenset[str] = frozenset(
    {
        # Core artifacts directories
        "ARTIFACTS_DIR",
        "_artifacts_dir",
        "WORKFLOW_PLUGIN_ARTIFACTS_DIR",
        # Log files (all resolve into artifacts dir or /tmp)
        "HOOK_ERROR_LOG",
        "HOOK_TIMING_LOG",
        "_HOOK_TIMING_LOG",
        "LOGFILE",
        "TIMEOUT_LOG",
        "UNTRACKED_LOG",
        "_HEAL_LOG",
        "LOG_FILE",   # tool-logging: $HOME/.claude/logs/*.jsonl
        "LOG_DIR",    # tool-logging: $HOME/.claude/logs/
        # State files (all in artifacts dir or /tmp)
        "VALIDATION_STATE_FILE",
        "REVIEW_STATE_FILE",
        "_REVIEW_DIFF_FILE",
        "_DIAG_FILE",
        "_DIAG_DIR",
        "JSONL_FILE",
        "TS_FILE",
        "COUNTER_FILE",
        "SNAPSHOT_FILE",
        "_TELEMETRY_FILE",
        "_LOCK_FILE",
        "HASH_FILE",    # cascade-failures: /tmp/claude-cascade-*/last-error-hash
        "SESSION_FILE", # tool-logging: $HOME/.claude/current-session-id
        "STATE_DIR",    # cascade-failures: /tmp/claude-cascade-*
        # atomic_write_file internals
        "tmpf",
        "target",  # mv "$tmpf" "$target" in atomic_write_file
        "target_dir",  # mkdir -p "$target_dir"
        # Lock dirs (atomic mkdir locking)
        "LOCK_DIR",
        "lock_dir",
        # get_artifacts_dir internals
        "new_dir",  # /tmp/workflow-plugin-<hash>
        # Repo-root sentinel files (written during pre-compact)
        "CHECKPOINT_MARKER_FILE",
    }
)

# Literal path prefixes that are safe write targets.
ALLOWED_PATH_PREFIXES: tuple[str, ...] = (
    "/tmp/",
    "/dev/null",
    "/dev/stderr",
    "/dev/stdout",
)

# File basenames that are sentinel/marker files written to repo root.
# These are intentional repo-root writes (not config or code).
ALLOWED_REPO_ROOT_PATTERNS: tuple[str, ...] = (
    ".checkpoint-needs-review",
)

# Commands that perform file writes (the last positional arg is the target).
WRITE_COMMANDS: frozenset[str] = frozenset(
    {"tee", "cp", "mv", "touch", "mkdir", "install"}
)

# Inline annotation to suppress a false positive.
SUPPRESS_COMMENT = "# write-ok"


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclass
class WriteTarget:
    """A detected file-write operation."""

    file: str
    line: int
    target: str  # the raw target path/variable expression
    operation: str  # >, >>, tee, cp, mv, etc.
    detection: str  # "ast" or "regex"
    source_line: str  # the original source line


@dataclass
class ScanResult:
    """Aggregated scan results."""

    violations: list[WriteTarget] = field(default_factory=list)
    allowed: list[WriteTarget] = field(default_factory=list)
    parse_stats: dict[str, int] = field(default_factory=lambda: {"ast": 0, "regex": 0, "skipped": 0})


# ---------------------------------------------------------------------------
# Line-level skip heuristics (applied before parsing)
# ---------------------------------------------------------------------------

# Lines that are clearly not write operations but contain > or >> tokens.
# These are skipped before any parsing to avoid false positives.
_SKIP_LINE_PATTERNS: list[re.Pattern[str]] = [
    # Arithmetic: (( expr > expr )) or (( expr >= expr ))
    re.compile(r"^\s*(?:if\s+)?\(\(.*\)\)"),
    # [[ ]] conditionals (bashlex can't parse these anyway)
    re.compile(r"\[\[.*\]\]"),
    # Embedded Python (common in hooks using python3 -c)
    re.compile(r"^\s*(?:if |elif |while |for |return |print\(|import |from |with |def |class |#)"),
    # Case pattern lines
    re.compile(r"^\s*[a-zA-Z0-9_*|\"']+\)\s*$"),
    # Here-string or here-doc markers
    re.compile(r"<<<"),
    # Comment-only lines that start with spaces then #
    re.compile(r"^\s*#"),
    # Lines that are just variable assignments with no redirect
    re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=(?!\s*\()"),
    # Usage/help echo lines containing -> as arrows
    re.compile(r"echo\s+[\"'].*->.*[\"']"),
]


def _should_skip_line(line: str) -> bool:
    """Return True if the line should be skipped (not a write operation)."""
    for pat in _SKIP_LINE_PATTERNS:
        if pat.search(line):
            return True
    return False


# ---------------------------------------------------------------------------
# Allowlist checker
# ---------------------------------------------------------------------------


def _is_allowed_target(target: str) -> bool:
    """Return True if the write target is in the allowlist."""
    # Strip quotes
    clean = target.strip("\"'")

    # Check literal path prefixes
    for prefix in ALLOWED_PATH_PREFIXES:
        if clean.startswith(prefix):
            return True

    # Check for allowed repo-root sentinel patterns
    for pattern in ALLOWED_REPO_ROOT_PATTERNS:
        if pattern in clean:
            return True

    # Check variable references: $VAR, ${VAR}, ${VAR:-...}
    # If ANY variable in the path is in the allowlist, the target is allowed.
    # This handles compound paths like $REPO_ROOT/$CHECKPOINT_MARKER_FILE.
    for var_match in re.finditer(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", clean):
        if var_match.group(1) in ALLOWED_VARIABLES:
            return True

    # Stderr/stdout redirect (>&2, >&1) is always allowed
    if clean in ("&2", "&1"):
        return True

    return False


# ---------------------------------------------------------------------------
# AST-based detection (bashlex)
# ---------------------------------------------------------------------------

def _walk_ast(node: Any, results: list[tuple[str, str]], _visited: set[int] | None = None) -> None:
    """Recursively walk a bashlex AST node, collecting (operation, target) pairs.

    Uses _visited (set of node ids) to prevent duplicate reporting when
    a redirect node appears both as a direct child and inside a command.
    """
    if _visited is None:
        _visited = set()

    node_id = id(node)
    if node_id in _visited:
        return
    _visited.add(node_id)

    kind = node.kind

    if kind == "redirect":
        if node.type in (">", ">>"):
            target_word = node.output.word if hasattr(node.output, "word") else str(node.output)
            results.append((node.type, target_word))

    elif kind == "command":
        parts = getattr(node, "parts", [])
        cmd_name = None
        args: list[str] = []
        for part in parts:
            if part.kind == "word":
                if cmd_name is None:
                    cmd_name = part.word
                else:
                    args.append(part.word)
            elif part.kind == "redirect":
                _walk_ast(part, results, _visited)

        if cmd_name in WRITE_COMMANDS:
            non_flag_args = [a for a in args if not a.startswith("-")]
            if cmd_name in ("tee", "cp", "mv") and non_flag_args:
                results.append((cmd_name, non_flag_args[-1]))
            elif cmd_name in ("touch", "mkdir", "install"):
                for a in non_flag_args:
                    results.append((cmd_name, a))

    elif kind == "pipeline":
        for part in getattr(node, "parts", []):
            if hasattr(part, "kind"):
                _walk_ast(part, results, _visited)
        return  # pipeline children already walked

    # Recurse into child nodes (but not for pipeline — already handled)
    for attr in ("parts", "list"):
        children = getattr(node, attr, None)
        if children:
            for child in children:
                if hasattr(child, "kind"):
                    _walk_ast(child, results, _visited)


def _detect_writes_ast(line: str) -> list[tuple[str, str]] | None:
    """Try to parse a line with bashlex and extract write operations.

    Returns list of (operation, target) tuples, or None if parsing fails.
    """
    if not HAS_BASHLEX:
        return None

    try:
        parts = bashlex.parse(line)
    except (bashlex.errors.ParsingError, NotImplementedError, IndexError, TypeError):
        return None

    results: list[tuple[str, str]] = []
    for node in parts:
        _walk_ast(node, results)
    return results


# ---------------------------------------------------------------------------
# Regex-based fallback detection
# ---------------------------------------------------------------------------

# Redirect: captures operator and target, avoiding false positives
_RE_REDIRECT = re.compile(
    r"(?<![<&0-9])"  # not preceded by <, &, or digit (avoids 2>, <<<, >&)
    r"(>{1,2})\s*"  # > or >>
    r"(?!&[12\s])"  # not >&1, >&2
    r"([^\s;|&)]+)"  # the target path
)

# Write commands
_RE_WRITE_CMD = re.compile(
    r"\b(tee|cp|mv|touch|mkdir)\s+"
    r"(?:-[a-zA-Z]+\s+)*"  # optional flags
    r"([^\s;|&)]+)"  # target path
)


def _detect_writes_regex(line: str) -> list[tuple[str, str]]:
    """Regex fallback: extract write operations from a line."""
    results: list[tuple[str, str]] = []

    for m in _RE_REDIRECT.finditer(line):
        op, target = m.group(1), m.group(2)
        # Additional validation: target should look like a path or variable
        if not re.match(r'[\$/"~.]', target) and not target.startswith("'"):
            continue
        results.append((op, target))

    for m in _RE_WRITE_CMD.finditer(line):
        cmd, target = m.group(1), m.group(2)
        results.append((cmd, target))

    return results


# ---------------------------------------------------------------------------
# File scanner
# ---------------------------------------------------------------------------


def scan_file(filepath: Path, relative_to: Path | None = None) -> ScanResult:
    """Scan a single shell file for disallowed write operations."""
    result = ScanResult()
    display_path = str(filepath.relative_to(relative_to)) if relative_to else str(filepath)

    with open(filepath) as f:
        lines = f.readlines()

    # Track whether we're inside a python3 -c heredoc or multi-line string
    in_embedded_code = False

    for lineno, raw_line in enumerate(lines, 1):
        line = raw_line.rstrip("\n")
        stripped = line.strip()

        # Skip blanks and pure comment lines
        if not stripped or stripped.startswith("#"):
            result.parse_stats["skipped"] += 1
            continue

        # Check for inline suppression
        if SUPPRESS_COMMENT in line:
            result.parse_stats["skipped"] += 1
            continue

        # Track embedded Python/heredoc blocks
        if re.search(r'python3?\s+-c\s+["\']', stripped) or re.search(r"<<['\"]?EOF", stripped):
            in_embedded_code = True
            result.parse_stats["skipped"] += 1
            continue
        if in_embedded_code:
            if stripped in ("EOF", "'", '"', "\"'", "\")", "')"):
                in_embedded_code = False
            result.parse_stats["skipped"] += 1
            continue

        # Skip lines that are clearly not write operations
        if _should_skip_line(stripped):
            result.parse_stats["skipped"] += 1
            continue

        # Try AST detection first
        ast_writes = _detect_writes_ast(stripped)

        if ast_writes is not None:
            result.parse_stats["ast"] += 1
            for op, target in ast_writes:
                wt = WriteTarget(
                    file=display_path,
                    line=lineno,
                    target=target,
                    operation=op,
                    detection="ast",
                    source_line=stripped,
                )
                if _is_allowed_target(target):
                    result.allowed.append(wt)
                else:
                    result.violations.append(wt)
        else:
            result.parse_stats["regex"] += 1
            regex_writes = _detect_writes_regex(stripped)
            for op, target in regex_writes:
                wt = WriteTarget(
                    file=display_path,
                    line=lineno,
                    target=target,
                    operation=op,
                    detection="regex",
                    source_line=stripped,
                )
                if _is_allowed_target(target):
                    result.allowed.append(wt)
                else:
                    result.violations.append(wt)

    return result


def scan_directory(hook_dir: Path) -> ScanResult:
    """Scan all .sh files under the hook directory."""
    combined = ScanResult()
    repo_root = hook_dir.parent.parent  # lockpick-workflow/hooks -> repo root

    sh_files = sorted(hook_dir.rglob("*.sh"))
    for sh_file in sh_files:
        file_result = scan_file(sh_file, relative_to=repo_root)
        combined.violations.extend(file_result.violations)
        combined.allowed.extend(file_result.allowed)
        for k in combined.parse_stats:
            combined.parse_stats[k] += file_result.parse_stats[k]

    return combined


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------


def _format_text(result: ScanResult, verbose: bool = False) -> str:
    """Format results as human-readable text."""
    lines: list[str] = []

    if result.violations:
        lines.append(f"FAIL: {len(result.violations)} disallowed write(s) in hook files\n")
        for v in result.violations:
            lines.append(f"  {v.file}:{v.line}  [{v.detection}] {v.operation} -> {v.target}")
            lines.append(f"    {v.source_line}")
        lines.append("")
        lines.append("To fix: redirect writes to $ARTIFACTS_DIR, /tmp/, or /dev/null.")
        lines.append(f"To suppress a false positive: add '{SUPPRESS_COMMENT}' to the line.")
    else:
        lines.append("OK: no disallowed writes in hook files")

    if verbose:
        lines.append("")
        lines.append(f"Detection stats: ast={result.parse_stats['ast']}, "
                      f"regex={result.parse_stats['regex']}, "
                      f"skipped={result.parse_stats['skipped']}")
        lines.append(f"Allowed writes: {len(result.allowed)}")
        if result.allowed:
            for a in result.allowed:
                lines.append(f"  {a.file}:{a.line}  [{a.detection}] {a.operation} -> {a.target}")

    return "\n".join(lines)


def _format_json(result: ScanResult) -> str:
    """Format results as JSON."""
    return json.dumps(
        {
            "ok": len(result.violations) == 0,
            "violations": [
                {
                    "file": v.file,
                    "line": v.line,
                    "target": v.target,
                    "operation": v.operation,
                    "detection": v.detection,
                    "source_line": v.source_line,
                }
                for v in result.violations
            ],
            "stats": {
                "violations": len(result.violations),
                "allowed_writes": len(result.allowed),
                **result.parse_stats,
            },
        },
        indent=2,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect disallowed file writes in hook scripts (bashlex AST + regex fallback)."
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Show allowed writes and parse stats")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--check", metavar="FILE", help="Check a single file instead of the hook directory")
    parser.add_argument(
        "--hook-dir",
        metavar="DIR",
        help="Hook directory to scan (default: auto-detected from script location)",
    )
    args = parser.parse_args()

    if not HAS_BASHLEX:
        print("WARNING: bashlex not installed — using regex-only detection", file=sys.stderr)

    if args.check:
        filepath = Path(args.check)
        if not filepath.is_file():
            print(f"error: file not found: {filepath}", file=sys.stderr)
            return 2
        result = scan_file(filepath)
    else:
        if args.hook_dir:
            hook_dir = Path(args.hook_dir)
        else:
            script_dir = Path(__file__).resolve().parent
            hook_dir = script_dir.parent / "hooks"
        if not hook_dir.is_dir():
            print(f"error: hook directory not found: {hook_dir}", file=sys.stderr)
            return 2
        result = scan_directory(hook_dir)

    if args.json:
        print(_format_json(result))
    else:
        print(_format_text(result, verbose=args.verbose))

    return 1 if result.violations else 0


if __name__ == "__main__":
    sys.exit(main())
