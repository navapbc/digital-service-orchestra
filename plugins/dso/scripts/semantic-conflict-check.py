#!/usr/bin/env python3
"""Analyze a unified diff for semantic conflicts across files using an LLM.

Sends a unified diff to the Anthropic API (haiku-tier model) and returns
structured JSON identifying cross-file semantic conflicts.

Usage:
    # From stdin
    git diff | python scripts/semantic-conflict-check.py

    # From file
    python scripts/semantic-conflict-check.py --diff-file changes.diff

    # Mock mode (no API call)
    python scripts/semantic-conflict-check.py --mock

Output (stdout): JSON
    {"conflicts": [...], "clean": true|false}

On failure: exit 0 with {"conflicts": [], "clean": true, "error": "<message>"}
"""

from __future__ import annotations

import argparse
import json
import sys

try:
    import anthropic
except ImportError:
    anthropic = None  # type: ignore[assignment]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MODEL = "claude-haiku-4-20250514"
DEFAULT_TIMEOUT = 30

SYSTEM_PROMPT = """\
You are a code review assistant that analyzes unified diffs for semantic conflicts \
across files. A semantic conflict is when changes in one file are logically \
incompatible with changes (or existing code) in another file within the same diff.

Examples of semantic conflicts:
- Type signature changes that break callers in other files
- Renamed/removed functions still referenced elsewhere
- Conflicting state assumptions (e.g., nullable vs non-nullable)
- Missing imports for newly used symbols
- Inconsistent configuration or constant changes

Analyze the provided diff and return ONLY valid JSON in this exact format:
{"conflicts": [{"files": ["file_a.py", "file_b.py"], "description": "...", "severity": "high|medium|low"}], "clean": true|false}

If there are no semantic conflicts, return:
{"conflicts": [], "clean": true}

Set "clean" to false if any conflicts exist, true otherwise.
Do NOT include any text outside the JSON object.\
"""


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------


def _graceful_error(message: str) -> dict:
    """Return a non-fatal error result."""
    return {"conflicts": [], "clean": True, "error": message}


def analyze_diff(diff_text: str, timeout: int = DEFAULT_TIMEOUT) -> dict:
    """Analyze a unified diff for semantic conflicts.

    Args:
        diff_text: The unified diff to analyze.
        timeout: Timeout in seconds for the Anthropic API call.

    Returns:
        Dict with 'conflicts', 'clean', and optionally 'error' keys.
    """
    # Empty diff -> clean, no LLM call needed
    if not diff_text or not diff_text.strip():
        return {"conflicts": [], "clean": True}

    # Check for anthropic SDK availability
    if anthropic is None:
        return _graceful_error("anthropic SDK not available (ImportError)")

    # Check for API key
    import os

    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        return _graceful_error("ANTHROPIC_API_KEY not set or empty")

    try:
        client = anthropic.Anthropic(api_key=api_key)
        response = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": diff_text}],
            timeout=timeout,
        )
        raw_text = response.content[0].text
    except Exception as exc:
        return _graceful_error(f"Anthropic API call failed: {exc}")

    # Parse LLM response
    try:
        data = json.loads(raw_text)
    except (json.JSONDecodeError, ValueError) as exc:
        return _graceful_error(f"Failed to parse LLM response as JSON: {exc}")

    # Validate structure
    if not isinstance(data, dict):
        return _graceful_error("LLM response is not a JSON object")

    conflicts = data.get("conflicts", [])
    if not isinstance(conflicts, list):
        return _graceful_error("LLM response 'conflicts' is not an array")

    clean = len(conflicts) == 0
    return {"conflicts": conflicts, "clean": clean}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Analyze a unified diff for semantic conflicts across files."
    )
    parser.add_argument(
        "--diff-file",
        type=str,
        default=None,
        help="Path to a file containing the unified diff (default: read from stdin)",
    )
    parser.add_argument(
        "--mock",
        action="store_true",
        help="Return a canned clean response without making an API call",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"Timeout in seconds for the Anthropic API call (default: {DEFAULT_TIMEOUT})",
    )
    args = parser.parse_args()

    if args.mock:
        result = {"conflicts": [], "clean": True}
        print(json.dumps(result))
        return 0

    # Read diff
    if args.diff_file:
        try:
            with open(args.diff_file) as f:
                diff_text = f.read()
        except OSError as exc:
            result = _graceful_error(f"Failed to read diff file: {exc}")
            print(json.dumps(result))
            return 0
    else:
        diff_text = sys.stdin.read()

    result = analyze_diff(diff_text, timeout=args.timeout)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
