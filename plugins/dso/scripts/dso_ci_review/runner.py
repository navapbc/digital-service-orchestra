"""dso_ci_review.runner — CLI entry point for CI code-review.

Environment variables (all optional):
    DSO_CI_REVIEW_DIFF_PATH   Path to a unified diff file to review.
                              If unset, reads from stdin.
    DSO_CI_REVIEW_OUTPUT_PATH Path to write findings JSON.
                              If unset, writes to stdout.
    DSO_CI_REVIEW_DRY_RUN     When set to "1", emit a canned empty-findings
                              response without calling any LLM. Useful for
                              smoke-testing the subprocess invocation path.
    DSO_CI_REVIEW_MODEL       Model identifier passed to the active provider
                              (optional; provider default is used when absent).
    CI_REVIEW_PROVIDER        Provider name (e.g. "anthropic", "openai").
                              Resolved by providers/config.py.

Exit codes:
    0  Success (findings JSON written)
    1  Error (details on stderr)
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile

from dso_ci_review.classifier import classify_tier
from dso_ci_review.dispatch import async_dispatch_specialists
from dso_ci_review.findings import merge_findings
from dso_ci_review.providers.config import AuthError, ConfigError, get_provider


def _read_diff() -> str:
    """Read the diff from DSO_CI_REVIEW_DIFF_PATH or stdin."""
    diff_path = os.environ.get("DSO_CI_REVIEW_DIFF_PATH")
    if diff_path:
        with open(diff_path, encoding="utf-8") as fh:
            return fh.read()
    return sys.stdin.read()


def _write_output(data: dict) -> None:
    """Serialize data as JSON to DSO_CI_REVIEW_OUTPUT_PATH or stdout.

    When DSO_CI_REVIEW_OUTPUT_PATH is set, the write is performed atomically
    via a temp file + os.replace() (rename syscall on POSIX) to prevent
    parsers from observing a partially-written file (DD3 requirement).
    """
    serialized = json.dumps(data, indent=2)
    output_path = os.environ.get("DSO_CI_REVIEW_OUTPUT_PATH")
    if output_path:
        dir_path = os.path.dirname(os.path.abspath(output_path))
        os.makedirs(dir_path, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w", dir=dir_path, suffix=".tmp", delete=False, encoding="utf-8"
        ) as tmp:
            tmp.write(serialized)
            tmp_path = tmp.name
        os.replace(tmp_path, output_path)  # atomic on POSIX (rename syscall)
    else:
        print(serialized)


_TIER_MODEL_DEFAULTS: dict[str, str] = {
    "light": "claude-haiku-4-5-20251001",
    "standard": "claude-sonnet-4-6",
    "deep": "claude-sonnet-4-6",
}


def _read_tier_model(tier: str, config_path: str | None = None) -> str:
    """Return the model for the given tier, reading from dso-config.conf when available.

    Resolution order:
      1. DSO_CI_REVIEW_MODEL env var (explicit override, any tier)
      2. model.<tier> key in config_path (or auto-detected repo config)
      3. _TIER_MODEL_DEFAULTS[tier] (haiku=light, sonnet=standard/deep)
    """
    env_override = os.environ.get("DSO_CI_REVIEW_MODEL")
    if env_override:
        return env_override

    # Locate config file
    if config_path is None:
        config_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
            ".claude",
            "dso-config.conf",
        )

    config_key = f"model.{tier}="
    if os.path.isfile(config_path):
        with open(config_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith(config_key):
                    value = line[len(config_key):].strip()
                    if value:
                        return value

    return _TIER_MODEL_DEFAULTS.get(tier, "claude-sonnet-4-6")


def _build_agents_for_tier(
    tier: str,
    diff_text: str,
    classification: dict,  # noqa: ARG001 — reserved for overlay use
    config_path: str | None = None,
) -> list[dict]:
    """Build agent dispatch list based on classifier tier."""
    base_model = _read_tier_model(tier, config_path)
    provider = os.environ.get("CI_REVIEW_PROVIDER", "anthropic")
    provider_chain = [provider]

    if tier == "deep":
        # Deep tier: 3 parallel specialists
        agents = [
            {
                "agent_id": "code-reviewer-deep-correctness",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
            },
            {
                "agent_id": "code-reviewer-deep-verification",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
            },
            {
                "agent_id": "code-reviewer-deep-hygiene",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
            },
        ]
    else:
        # light or standard: single agent
        agents = [
            {
                "agent_id": f"code-reviewer-{tier}",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
            }
        ]

    return agents


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

    # Validate provider configuration before dispatching any LLM calls.
    # Resolve provider from CI_REVIEW_PROVIDER env var, falling back to
    # model.provider in dso-config.conf, then defaulting to "anthropic".
    _ci_provider = os.environ.get("CI_REVIEW_PROVIDER", "").strip()
    if not _ci_provider:
        # Attempt to read model.provider from dso-config.conf as a fallback
        _config_path = os.path.join(
            os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            ),
            ".claude",
            "dso-config.conf",
        )
        if os.path.isfile(_config_path):
            with open(_config_path, encoding="utf-8") as _f:
                for _line in _f:
                    _line = _line.strip()
                    if _line.startswith("ci_review.provider="):
                        _ci_provider = _line[len("ci_review.provider=") :].strip()
                        break
                    if not _ci_provider and _line.startswith("model.provider="):
                        _ci_provider = _line[len("model.provider=") :].strip()
        if not _ci_provider:
            _ci_provider = "anthropic"
    # get_provider(name=...) raises AuthError when the required API key is absent.
    try:
        get_provider(name=_ci_provider)
    except (ConfigError, AuthError) as exc:
        kind = "provider config" if isinstance(exc, ConfigError) else "provider auth"
        print(f"ERROR: {kind}: {exc}", file=sys.stderr)
        return 1

    try:
        # Step 1: classify tier
        classification = classify_tier(diff_text)
        tier = classification["selected_tier"]

        # Step 2: build agent list based on tier
        agents = _build_agents_for_tier(tier, diff_text, classification)

        # Step 3: dispatch agents (async)
        all_findings = asyncio.run(async_dispatch_specialists(agents))

        # Step 4: merge findings
        merged = merge_findings(*all_findings)

        # Step 5: write output
        _write_output(merged)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: LLM call failed: {exc}", file=sys.stderr)
        return 1

    # Detect all-specialist-error: every finding is a specialist_error with no real review.
    # Exit 1 so the CI job fails visibly instead of silently no-op'ing (fcea-6e83).
    all_specialist_errors = merged.get("findings") and all(
        f.get("type") == "specialist_error" for f in merged["findings"]
    )
    if all_specialist_errors:
        print(
            "ERROR: all specialist dispatches failed — no review findings produced "
            "(check litellm installation and API key configuration)",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
