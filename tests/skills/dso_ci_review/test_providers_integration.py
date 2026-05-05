"""Integration tests for Anthropic and OpenAI providers against fixture corpus.

Testing mode: GREEN — exercises each provider end-to-end against fixture diffs,
mocking at the litellm.completion boundary since both providers call litellm
(not raw HTTP), so respx/httpx interception cannot be used here.

Both providers do a deferred ``import litellm`` inside their ``review_diff``
function body.  We inject a fake ``litellm`` module into ``sys.modules``
before the provider is imported so the deferred import resolves to our stub.

DD1 coverage: integration test exercising each provider end-to-end against fixture diffs.
"""

from __future__ import annotations

import json
import pathlib
import sys
import types
from unittest.mock import MagicMock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURE_DIFF = (
    REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus" / "fixture-diff.txt"
)
_SCRIPTS_DIR = str(REPO_ROOT / "plugins" / "dso" / "scripts")


def _make_litellm_response(findings: list) -> MagicMock:
    """Build a MagicMock that matches the litellm.completion response shape.

    litellm returns a ModelResponse object; we access:
        response.choices[0].message.content

    where content is a JSON string.
    """
    content = json.dumps({"findings": findings})
    mock_message = MagicMock()
    mock_message.content = content
    mock_choice = MagicMock()
    mock_choice.message = mock_message
    mock_response = MagicMock()
    mock_response.choices = [mock_choice]
    return mock_response


def _inject_fake_litellm(monkeypatch, return_value: MagicMock) -> MagicMock:
    """Inject a fake ``litellm`` module into sys.modules with a mocked completion.

    The providers do ``import litellm`` inside their function body (deferred import).
    When litellm is not installed we must stub the entire module so the import
    resolves without ModuleNotFoundError.

    Returns the mock ``completion`` callable so callers can assert on call count.
    """
    mock_completion = MagicMock(return_value=return_value)
    fake_litellm = types.ModuleType("litellm")
    fake_litellm.completion = mock_completion  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "litellm", fake_litellm)
    return mock_completion


def test_anthropic_provider_integration(monkeypatch):
    """
    Given: fixture diff + litellm.completion mocked to return canned Anthropic findings
    When: AnthropicProvider().review_diff(corpus_diff) is called
    Then: returns dict with 'findings' list matching the canned response
    """
    diff_text = FIXTURE_DIFF.read_text()
    canned_findings = [
        {
            "severity": "minor",
            "description": "Test finding from Anthropic integration test",
            "cited_lines": ["file.py:1"],
        }
    ]
    mock_response = _make_litellm_response(canned_findings)
    mock_completion = _inject_fake_litellm(monkeypatch, mock_response)

    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key-anthropic-integration")

    # Ensure the plugin package is importable; evict cached module so the
    # deferred ``import litellm`` picks up our stub.
    if _SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, _SCRIPTS_DIR)
    monkeypatch.delitem(sys.modules, "dso_ci_review.providers.anthropic", raising=False)

    from dso_ci_review.providers.anthropic import AnthropicProvider

    provider = AnthropicProvider()
    result = provider.review_diff(diff_text)

    # Verify litellm.completion was actually called (provider went through the
    # full code path, not a short-circuit)
    assert mock_completion.called, (
        "litellm.completion must be called by AnthropicProvider"
    )

    # Behavioral assertions: output shape must match provider contract
    assert "findings" in result, (
        f"AnthropicProvider.review_diff must return dict with 'findings' key; got: {result!r}"
    )
    assert isinstance(result["findings"], list), (
        f"'findings' must be a list; got {type(result['findings'])}"
    )
    # Verify the canned findings were passed through correctly
    assert len(result["findings"]) == len(canned_findings), (
        f"Expected {len(canned_findings)} finding(s), got {len(result['findings'])}"
    )
    assert result["findings"][0]["severity"] == "minor", (
        f"Expected severity 'minor'; got {result['findings'][0].get('severity')!r}"
    )


def test_openai_provider_integration(monkeypatch):
    """
    Given: fixture diff + litellm.completion mocked to return canned OpenAI findings
    When: OpenAIProvider().review_diff(corpus_diff) is called
    Then: returns dict with 'findings' list matching the canned response
    """
    diff_text = FIXTURE_DIFF.read_text()
    canned_findings = [
        {
            "severity": "minor",
            "description": "OpenAI test finding from integration test",
            "cited_lines": ["file.py:2"],
        }
    ]
    mock_response = _make_litellm_response(canned_findings)
    mock_completion = _inject_fake_litellm(monkeypatch, mock_response)

    monkeypatch.setenv("OPENAI_API_KEY", "test-key-openai-integration")

    # Ensure the plugin package is importable; evict cached module so the
    # deferred ``import litellm`` picks up our stub.
    if _SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, _SCRIPTS_DIR)
    monkeypatch.delitem(sys.modules, "dso_ci_review.providers.openai", raising=False)

    from dso_ci_review.providers.openai import OpenAIProvider

    provider = OpenAIProvider()
    result = provider.review_diff(diff_text)

    # Verify litellm.completion was actually called
    assert mock_completion.called, "litellm.completion must be called by OpenAIProvider"

    # Behavioral assertions: output shape must match provider contract
    assert "findings" in result, (
        f"OpenAIProvider.review_diff must return dict with 'findings' key; got: {result!r}"
    )
    assert isinstance(result["findings"], list), (
        f"'findings' must be a list; got {type(result['findings'])}"
    )
    # Verify the canned findings were passed through correctly
    assert len(result["findings"]) == len(canned_findings), (
        f"Expected {len(canned_findings)} finding(s), got {len(result['findings'])}"
    )
    assert result["findings"][0]["severity"] == "minor", (
        f"Expected severity 'minor'; got {result['findings'][0].get('severity')!r}"
    )
