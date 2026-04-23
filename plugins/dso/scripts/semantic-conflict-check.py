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
import os
import subprocess
import sys

try:
    import anthropic
except ImportError:
    anthropic = None  # type: ignore[assignment]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_TIMEOUT = 30


def _resolve_model_id(tier: str) -> str:
    """Resolve a model ID for the given tier via resolve-model-id.sh.

    Failure is FATAL — exits with code 1 if the config key is absent or the
    script fails.  This is a deliberate departure from the existing graceful
    degradation pattern (SC3).

    When WORKFLOW_CONFIG_FILE is set in the environment, it is passed explicitly
    as the second argument to resolve-model-id.sh to ensure correct config
    isolation (e.g., in pipeline contexts where env inheritance is limited).
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    resolve_path = os.path.join(script_dir, "resolve-model-id.sh")
    cmd = ["bash", resolve_path, tier]
    config_file = os.environ.get("WORKFLOW_CONFIG_FILE", "").strip()
    if config_file:
        cmd.append(config_file)
    try:
        result = subprocess.check_output(
            cmd,
            stderr=subprocess.PIPE,
            text=True,
        )
        model_id = result.strip()
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip() if exc.stderr else ""
        print(
            f"FATAL: resolve-model-id.sh failed for tier '{tier}': {stderr}",
            file=sys.stderr,
        )
        sys.exit(1)
    if not model_id:
        print(
            f"FATAL: resolve-model-id.sh returned empty model ID for tier '{tier}'",
            file=sys.stderr,
        )
        sys.exit(1)
    return model_id


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


def analyze_diff(
    diff_text: str, timeout: int = DEFAULT_TIMEOUT, model: str | None = None
) -> dict:
    """Analyze a unified diff for semantic conflicts.

    Args:
        diff_text: The unified diff to analyze.
        timeout: Timeout in seconds for the Anthropic API call.
        model: Model ID to use.  When None the caller is responsible for
               ensuring a model has been resolved before calling this function.

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
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        return _graceful_error("ANTHROPIC_API_KEY not set or empty")

    resolved_model = model or ""
    if not resolved_model:
        return _graceful_error("No model ID provided to analyze_diff")

    try:
        client = anthropic.Anthropic(api_key=api_key)
        response = client.messages.create(
            model=resolved_model,
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

    try:
        model = _resolve_model_id("haiku")
    except (RuntimeError, SystemExit):
        # Fail-open: haiku model not configured in this project — skip the check (f845-1a0a)
        result = _graceful_error(
            "haiku model ID not configured — semantic conflict check skipped"
        )
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

    result = analyze_diff(diff_text, timeout=args.timeout, model=model)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
