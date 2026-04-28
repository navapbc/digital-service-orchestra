#!/usr/bin/env python3
"""Assertion-Regression Gate: Test Regression Check.

Reads a unified diff from stdin and detects assertion weakening in test files.
Emits a JSON gate signal conforming to gate-signal-schema.md.

Usage:
    assertion-regression-check.py [--intent-aligned] [--test-dir <path>]

Flags:
    --intent-aligned   Suppresses all signals per epic SC3. Always emits
                       triggered:false when present.
    --test-dir <path>  Constrains which diff files are analyzed. Only files
                       under this path that match test_*.py or *_test.py are
                       considered. Files outside this directory are ignored.

Output: single JSON object on stdout conforming to gate-signal-schema.md
    gate_id     = "assertion_regression"
    signal_type = "primary"
    triggered   = true | false
    evidence    = human-readable explanation
    confidence  = "high" | "medium" | "low"

Exit codes:
    0   always (graceful degradation on malformed input)
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import PurePosixPath

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GATE_ID = "assertion_regression"
SIGNAL_TYPE = "primary"

# Assertion methods recognized for detection
ASSERTION_PATTERN = re.compile(
    r"\b(assert\w*|assertEqual|assertTrue|assertFalse|assertIn|assertNotIn"
    r"|assertIs|assertIsNot|assertIsNone|assertIsNotNone|assertRaises"
    r"|assertAlmostEqual|assertNotAlmostEqual|assertGreater|assertGreaterEqual"
    r"|assertLess|assertLessEqual|assertRegex|assertNotRegex|assertCountEqual"
    r"|assertMultiLineEqual|assertSequenceEqual|assertListEqual|assertTupleEqual"
    r"|assertSetEqual|assertDictEqual)\s*\(",
    re.IGNORECASE,
)

# Weak (non-specific) assertion methods — checking existence/truth, not a value
WEAK_ASSERTIONS = frozenset(
    [
        "assertisnotnone",
        "assertisnone",
        "asserttrue",
        "assertfalse",
        "assertis",
        "assertisnot",
        "assertin",
        "assertnotin",
    ]
)

# Skip/xfail decorator patterns
SKIP_XFAIL_PATTERN = re.compile(
    r"@\s*(pytest\.mark\.(skip|xfail)|unittest\.skip)\b",
    re.IGNORECASE,
)

# Literal value pattern: int, float, or quoted string
LITERAL_PATTERN = re.compile(
    r"""^[\s\w.]*\(      # opening paren of assertion
        \s*[^,)]+        # first arg
        ,\s*             # comma
        (?:              # literal: int, float, or quoted string
            -?\d+(?:\.\d+)?
            |"[^"]*"
            |'[^']*'
        )
        \s*\)            # closing paren
    """,
    re.VERBOSE,
)


def _is_literal_value(token: str) -> bool:
    """Return True if token looks like a Python literal (int, float, or quoted string)."""
    token = token.strip()
    if re.fullmatch(r"-?\d+(?:\.\d+)?", token):
        return True
    if re.fullmatch(r'"[^"]*"', token) or re.fullmatch(r"'[^']*'", token):
        return True
    return False


def _extract_method_and_args(line: str) -> tuple[str, list[str]] | None:
    """Extract assertion method name and arguments from a line.

    Returns (method_name_lower, [arg1, arg2, ...]) or None if not an assertion.
    Handles calls with nested function calls like assertEqual(foo(x), 42).
    Uses a balanced-paren scan to find the true closing paren of the call.
    """
    # Find the method name and the position of its opening paren
    m = re.search(r"(\w+)\s*\(", line)
    if not m:
        return None
    method = m.group(1).lower()
    # Check it's an assertion method
    if not re.match(
        r"assert|equal|true|false|none|raises|almost|greater|less|regex|count"
        r"|multiline|sequence|list|tuple|set|dict",
        method,
        re.IGNORECASE,
    ):
        if not method.startswith("assert"):
            return None

    # Walk from the opening paren, tracking depth to find the balanced close
    open_pos = m.end() - 1  # position of '('
    depth = 0
    args_raw_chars: list[str] = []
    for ch in line[open_pos:]:
        if ch == "(":
            depth += 1
            if depth > 1:
                args_raw_chars.append(ch)
        elif ch == ")":
            depth -= 1
            if depth == 0:
                break
            args_raw_chars.append(ch)
        else:
            args_raw_chars.append(ch)

    args_raw = "".join(args_raw_chars)

    # Split on top-level comma (ignore nested parens)
    args: list[str] = []
    depth = 0
    current: list[str] = []
    for ch in args_raw:
        if ch in "([{":
            depth += 1
            current.append(ch)
        elif ch in ")]}":
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            args.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
    if current:
        args.append("".join(current).strip())
    return method, args


def _is_test_file(filename: str, test_dir: str | None) -> bool:
    """Return True if filename is considered a test file."""
    p = PurePosixPath(filename)
    name = p.name
    # Must match test_*.py or *_test.py
    if not (name.startswith("test_") and name.endswith(".py")) and not (
        name.endswith("_test.py")
    ):
        return False
    # If test_dir is specified, file must be under that directory
    if test_dir is not None:
        test_dir_clean = test_dir.rstrip("/")
        str_p = str(p)
        if not (str_p.startswith(test_dir_clean + "/") or str_p == test_dir_clean):
            return False
    return True


def _parse_diff(diff_text: str) -> dict[str, dict[str, list[str]]]:
    """Parse unified diff into per-file added/removed lines.

    Returns {filename: {"added": [...], "removed": [...]}}
    """
    files: dict[str, dict[str, list[str]]] = {}
    current_file: str | None = None

    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            # Extract filename: "+++ b/path/to/file.py" or "+++ path/to/file.py"
            path = line[4:].strip()
            if path.startswith("b/"):
                path = path[2:]
            current_file = path
            if current_file not in files:
                files[current_file] = {"added": [], "removed": []}
        elif line.startswith("--- "):
            # Ignore; we track by +++ header
            continue
        elif line.startswith("+") and current_file is not None:
            if not line.startswith("+++"):
                files[current_file]["added"].append(line[1:])
        elif line.startswith("-") and current_file is not None:
            if not line.startswith("---"):
                files[current_file]["removed"].append(line[1:])

    return files


def _count_assertions(lines: list[str]) -> int:
    """Count assertion calls in a list of lines."""
    return sum(1 for line in lines if ASSERTION_PATTERN.search(line))


def _detect_skip_xfail_added(added_lines: list[str]) -> bool:
    """Return True if any skip/xfail decorator was added."""
    return any(SKIP_XFAIL_PATTERN.search(line) for line in added_lines)


def _analyze_assertion_removals(
    removed_lines: list[str], added_lines: list[str]
) -> dict[str, bool | int]:
    """Analyze assertion changes between removed and added lines.

    Returns a dict with:
        unexplained_removals (int): Number of removed assertions NOT explained
            by a specific-to-specific value swap (e.g., 42→57, "foo"→"bar").
        specificity_reduced (bool): True if any specific assertion was weakened
            (e.g., assertEqual→assertIsNotNone) or a literal was replaced by
            a variable (assertEqual(x, 42)→assertEqual(x, result)).

    Rules:
    - A removed assertion is "explained" if it is matched 1:1 with an added
      assertion using the same method AND both arguments are literals. In that
      case the swap is benign (specific-to-specific).
    - Any other removal (no match, different method, literal→variable) is
      "unexplained" and indicates a regression.
    - specificity_reduced covers: method weakened (assertEqual→assertIsNotNone)
      OR literal expected-value replaced by variable.
    """

    # Parse all assertion lines
    def _parse_assertions(lines: list[str]) -> list[tuple[str, list[str]]]:
        result: list[tuple[str, list[str]]] = []
        for line in lines:
            parsed = _extract_method_and_args(line)
            if parsed is not None:
                method, args = parsed
                if method.lower().startswith("assert"):
                    result.append((method.lower(), args))
        return result

    removed_assertions = _parse_assertions(removed_lines)
    added_assertions = _parse_assertions(added_lines)

    unexplained_removals = 0
    specificity_reduced = False

    # Track which added assertions have been "used" for matching
    used_added: list[bool] = [False] * len(added_assertions)

    for rem_method, rem_args in removed_assertions:
        rem_is_specific = rem_method not in WEAK_ASSERTIONS
        matched = False
        this_reduced = False  # per-iteration flag: did THIS removal reduce specificity?

        for i, (add_method, add_args) in enumerate(added_assertions):
            if used_added[i]:
                continue

            # Case A: Same specific method, same first arg, both expected values are literals
            # e.g. assertEqual(result, 42) → assertEqual(result, 57): benign swap
            if (
                add_method == rem_method
                and rem_is_specific
                and add_method not in WEAK_ASSERTIONS
                and len(rem_args) >= 2
                and len(add_args) >= 2
                and rem_args[0].strip() == add_args[0].strip()  # same variable/expr
            ):
                rem_expected = rem_args[1]
                add_expected = add_args[1]
                if _is_literal_value(rem_expected) and _is_literal_value(add_expected):
                    # Benign specific-to-specific swap — mark as explained
                    used_added[i] = True
                    matched = True
                    break

            # Case B: Method weakened (specific → weak)
            if rem_is_specific and add_method in WEAK_ASSERTIONS:
                specificity_reduced = True
                this_reduced = True
                # This is a regression — count as unexplained but don't double-count
                used_added[i] = True
                matched = True  # Matched to a weaker replacement
                break

            # Case C: Same specific method, same first arg, literal → variable
            # e.g. assertEqual(result, 42) → assertEqual(result, expected_result)
            if (
                add_method == rem_method
                and rem_is_specific
                and add_method not in WEAK_ASSERTIONS
                and len(rem_args) >= 2
                and len(add_args) >= 2
                and rem_args[0].strip() == add_args[0].strip()  # same variable/expr
            ):
                rem_expected = rem_args[1]
                add_expected = add_args[1]
                if _is_literal_value(rem_expected) and not _is_literal_value(
                    add_expected
                ):
                    specificity_reduced = True
                    this_reduced = True
                    used_added[i] = True
                    matched = True
                    break

        if not matched:
            # Removed assertion with no corresponding added assertion → unexplained
            unexplained_removals += 1
        elif this_reduced and matched:
            # Was matched but to a weaker version — still count as regression removal
            unexplained_removals += 1

    return {
        "unexplained_removals": unexplained_removals,
        "specificity_reduced": specificity_reduced,
    }


def _analyze_file(added_lines: list[str], removed_lines: list[str]) -> tuple[bool, str]:
    """Analyze a single test file's diff for regressions.

    Returns (triggered, evidence_snippet).
    """
    reasons: list[str] = []

    # 1. Skip/xfail additions
    if _detect_skip_xfail_added(added_lines):
        reasons.append("skip/xfail decorator added")

    # 2. Assertion removal and specificity checks
    # Trigger policy: ANY assertion removal triggers UNLESS the removal is
    # entirely explained by a specific-to-specific value swap (same method,
    # both literal values changed, e.g., assertEqual(x,42)→assertEqual(x,57)).
    removal_result = _analyze_assertion_removals(removed_lines, added_lines)
    if removal_result["unexplained_removals"] > 0:
        reasons.append(
            f"assertion removed: {removal_result['unexplained_removals']} assertion(s) removed"
        )

    # 3. Specificity reduction (weakened matchers or literal→variable)
    #    Check even when no net removal (e.g., assertEqual→assertIsNotNone same count)
    if removal_result["specificity_reduced"]:
        reasons.append(
            "assertion specificity reduced (weakened matcher or literal→variable)"
        )

    triggered = len(reasons) > 0
    evidence = "; ".join(reasons) if reasons else "no assertion regression detected"
    return triggered, evidence


def _emit(triggered: bool, evidence: str, confidence: str) -> None:
    """Print gate signal JSON to stdout and exit 0."""
    signal = {
        "gate_id": GATE_ID,
        "triggered": triggered,
        "signal_type": SIGNAL_TYPE,
        "evidence": evidence,
        "confidence": confidence,
    }
    print(json.dumps(signal))
    sys.exit(0)


def main() -> None:
    """Entry point."""
    # ── Argument parsing ─────────────────────────────────────────────────────
    intent_aligned = False
    test_dir: str | None = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--intent-aligned":
            intent_aligned = True
        elif args[i] == "--test-dir" and i + 1 < len(args):
            test_dir = args[i + 1]
            i += 1
        i += 1

    # ── Intent-aligned suppression ───────────────────────────────────────────
    if intent_aligned:
        _emit(
            False,
            "Test regression check suppressed: --intent-aligned flag passed "
            "(Intent Gate reported intent-aligned; test changes are expected and intentional)",
            "high",
        )
        return  # unreachable after _emit exits, but keeps linter happy

    # ── Read diff from stdin ─────────────────────────────────────────────────
    try:
        diff_text = sys.stdin.read()
    except Exception:
        _emit(False, "Failed to read diff from stdin", "high")
        return

    # ── Parse diff ───────────────────────────────────────────────────────────
    try:
        file_diffs = _parse_diff(diff_text)
    except Exception:
        _emit(False, "Malformed or unparseable diff input", "high")
        return

    if not file_diffs:
        _emit(False, "No file changes detected in diff", "high")
        return

    # ── Analyze test files ───────────────────────────────────────────────────
    overall_triggered = False
    evidence_parts: list[str] = []
    test_files_found = 0

    for filename, changes in file_diffs.items():
        if not _is_test_file(filename, test_dir):
            continue
        test_files_found += 1
        triggered, file_evidence = _analyze_file(changes["added"], changes["removed"])
        if triggered:
            overall_triggered = True
            evidence_parts.append(f"{filename}: {file_evidence}")

    if test_files_found == 0:
        _emit(
            False,
            "No test files found in diff (no test_*.py or *_test.py files)",
            "high",
        )
        return

    if overall_triggered:
        evidence = "; ".join(evidence_parts)
        _emit(True, evidence, "high")
    else:
        _emit(
            False,
            f"No assertion regressions detected in {test_files_found} test file(s)",
            "high",
        )


if __name__ == "__main__":
    main()
