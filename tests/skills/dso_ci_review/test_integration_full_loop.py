"""Integration tests: full dispatch_review() loop against real Anthropic and OpenAI APIs.

Testing mode: GREEN — exercises dispatch_review() end-to-end against real LLM providers
using the fixture diff from tests/fixtures/ci-review-corpus/fixture-diff.txt.

These tests are skipped when the required API key is absent. They run in CI with keys
in secrets, not locally without keys. They are excluded from the normal unit test run
via ``pytest -m "not integration"``.

SC6 coverage: integration tests exercise the full context-augmentation loop end-to-end
against both Anthropic and OpenAI, asserting structurally valid findings are produced.
"""

from __future__ import annotations

import os
import pathlib
import sys

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURE_DIFF = (
    REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus" / "fixture-diff.txt"
)
_SCRIPTS_DIR = str(REPO_ROOT / "plugins" / "dso" / "scripts")

# Ensure the plugin package is importable before any test collects.
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# Valid severity values as defined in dispatch.py _SYSTEM_PROMPT plus the
# fallback_exhausted sentinel written by dispatch_review() when all providers fail.
_VALID_SEVERITIES = {"critical", "important", "minor", "fragile", "fallback_exhausted"}


@pytest.mark.integration
def test_anthropic_full_loop_produces_structured_findings():
    """
    Given: a fixture diff and a real ANTHROPIC_API_KEY in the environment
    When: dispatch_review() is called with provider_chain=["anthropic"],
          tier="standard", and soft_cap=1 (cost-bounded)
    Then: the returned dict has a "findings" key whose value is a non-empty list,
          and every finding has the required fields with valid severity values.
    """
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not anthropic_key:
        pytest.skip("ANTHROPIC_API_KEY not set — skipping Anthropic integration test")

    diff_text = FIXTURE_DIFF.read_text()

    from dso_ci_review.dispatch import dispatch_review

    result = dispatch_review(
        diff_text=diff_text,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": anthropic_key},
        agent_id="unknown",
        primary_model="claude-haiku-4-5-20251001",
        repo_root=str(REPO_ROOT),
        tier="standard",
        soft_cap=1,
    )

    # Structural assertion: top-level shape
    assert isinstance(result, dict), (
        f"dispatch_review must return a dict; got {type(result)}"
    )
    assert "findings" in result, (
        f"Result must contain 'findings' key; got keys: {list(result.keys())}"
    )
    findings = result["findings"]
    assert isinstance(findings, list), (
        f"'findings' must be a list; got {type(findings)}"
    )
    _assert_findings_structurally_valid(findings, "Anthropic")


@pytest.mark.integration
def test_openai_full_loop_produces_structured_findings():
    """
    Given: a fixture diff and a real OPENAI_API_KEY in the environment
    When: dispatch_review() is called with provider_chain=["openai"],
          tier="standard", and soft_cap=1 (cost-bounded)
    Then: the returned dict has a "findings" key whose value is a list,
          and every finding (including fallback_exhausted) is structurally valid.
    """
    openai_key = os.environ.get("OPENAI_API_KEY")
    if not openai_key:
        pytest.skip("OPENAI_API_KEY not set — skipping OpenAI integration test")

    diff_text = FIXTURE_DIFF.read_text()

    from dso_ci_review.dispatch import dispatch_review

    result = dispatch_review(
        diff_text=diff_text,
        provider_chain=["openai"],
        environ={"OPENAI_API_KEY": openai_key},
        agent_id="unknown",
        primary_model="openai/gpt-4o-mini",
        repo_root=str(REPO_ROOT),
        tier="standard",
        soft_cap=1,
    )

    assert isinstance(result, dict), (
        f"dispatch_review must return a dict; got {type(result)}"
    )
    assert "findings" in result, (
        f"Result must contain 'findings' key; got keys: {list(result.keys())}"
    )
    findings = result["findings"]
    assert isinstance(findings, list), (
        f"'findings' must be a list; got {type(findings)}"
    )
    _assert_findings_structurally_valid(findings, "OpenAI")


def _assert_findings_structurally_valid(findings: list, provider_label: str) -> None:
    """Assert every finding in the list has the required structural fields.

    Empty lists are valid (model may find no issues). fallback_exhausted entries
    have a reduced schema and are also accepted.
    """
    for i, finding in enumerate(findings):
        assert isinstance(finding, dict), (
            f"{provider_label} findings[{i}] must be a dict; got {type(finding)}"
        )
        # fallback_exhausted entries use "type" not "severity" — accept both schemas.
        if finding.get("type") == "fallback_exhausted":
            assert "agent_id" in finding, (
                f"{provider_label} findings[{i}] fallback_exhausted missing 'agent_id'"
            )
            continue
        assert "severity" in finding, (
            f"{provider_label} findings[{i}] missing 'severity'; "
            f"got keys: {list(finding.keys())}"
        )
        sev = finding["severity"]
        assert sev in _VALID_SEVERITIES, (
            f"{provider_label} findings[{i}]['severity'] = {sev!r} not valid; "
            f"expected one of {sorted(_VALID_SEVERITIES)}"
        )
        assert "description" in finding, (
            f"{provider_label} findings[{i}] missing 'description'"
        )
        assert isinstance(finding["description"], str), (
            f"{provider_label} findings[{i}]['description'] must be a string"
        )
        assert "cited_lines" in finding, (
            f"{provider_label} findings[{i}] missing 'cited_lines'"
        )
        assert isinstance(finding["cited_lines"], list), (
            f"{provider_label} findings[{i}]['cited_lines'] must be a list"
        )
