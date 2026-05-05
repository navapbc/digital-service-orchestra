"""dso_ci_review.runner — CLI entry point for CI code-review.

Environment variables (all optional):
    DSO_CI_REVIEW_DIFF_PATH   Path to a unified diff file to review.
                              If unset, reads from stdin.
    DSO_CI_REVIEW_OUTPUT_PATH Path to write findings JSON.
                              If unset, writes to stdout.
    DSO_CI_REVIEW_DRY_RUN     When set to "1", emit a canned empty-findings
                              response without calling any LLM. Useful for
                              smoke-testing the subprocess invocation path.
    DSO_CI_REVIEW_MODEL       LiteLLM model identifier (optional; provider
                              default is used when absent).

Exit codes:
    0  Success (findings JSON written)
    1  Error (details on stderr)
"""

from __future__ import annotations

import json
import os
import sys


def _read_diff() -> str:
    """Read the diff from DSO_CI_REVIEW_DIFF_PATH or stdin."""
    diff_path = os.environ.get("DSO_CI_REVIEW_DIFF_PATH")
    if diff_path:
        with open(diff_path, encoding="utf-8") as fh:
            return fh.read()
    return sys.stdin.read()


def _write_output(data: dict) -> None:
    """Serialize data as JSON to DSO_CI_REVIEW_OUTPUT_PATH or stdout."""
    output_path = os.environ.get("DSO_CI_REVIEW_OUTPUT_PATH")
    serialized = json.dumps(data, indent=2)
    if output_path:
        with open(output_path, "w", encoding="utf-8") as fh:
            fh.write(serialized)
    else:
        print(serialized)


def main() -> int:
    """Run the CI review and return an exit code."""
    dry_run = os.environ.get("DSO_CI_REVIEW_DRY_RUN") == "1"

    if dry_run:
        findings = {"findings": [], "dry_run": True}
        _write_output(findings)
        return 0

    diff_text = _read_diff()
    if not diff_text.strip():
        _write_output({"findings": []})
        return 0

    from dso_ci_review.providers.anthropic import review_diff

    model = os.environ.get("DSO_CI_REVIEW_MODEL")
    kwargs: dict = {}
    if model:
        kwargs["model"] = model

    try:
        result = review_diff(diff_text, **kwargs)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: LLM call failed: {exc}", file=sys.stderr)
        return 1

    _write_output(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
