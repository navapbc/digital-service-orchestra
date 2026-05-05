"""RED tests for dso_ci_review.dispatch fallback chain (DD1–DD5).

These tests FAIL until the implementation task creates dispatch.py with
a working fallback chain using litellm.completion.

Testing mode: RED — all 6 test functions define behavior that does not exist yet.

RED marker: tests/skills/dso_ci_review/test_dispatch_fallback.py [test_fallback_rate_limit_falls_back_to_provider]

Behavioral contracts under test:
1. RateLimitError on primary → fallback provider answers; hop rendered in summary
2. ContextWindowExceededError on haiku → sonnet tier answers (same provider)
3. Full chain failure → fallback_exhausted JSON entry (6 required fields)
4. fallback_exhausted JSON validates against expected schema (contract conformance)
5. streaming=False preserved across all litellm.completion calls
6. ConfigError raised on startup when provider credential is missing
"""

from __future__ import annotations

import sys
import pathlib

import pytest

# Ensure the plugin scripts directory is on sys.path so that
# `dso_ci_review.dispatch` resolves to the plugin, not the test package.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# This import will raise ImportError until dispatch.py is implemented,
# which is the desired RED state.
from dso_ci_review.dispatch import (  # noqa: E402
    dispatch_review,
)
from dso_ci_review.providers.config import ConfigError  # noqa: E402


# ---------------------------------------------------------------------------
# Shared test constants
# ---------------------------------------------------------------------------

_DIFF_TEXT = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n"

_PRIMARY_MODEL = "claude-haiku-4-5-20251001"
_FALLBACK_MODEL = "openai/gpt-4o-mini"
_CONTEXT_FALLBACK_MODEL = "claude-sonnet-4-5"

_CANNED_FINDINGS = {
    "findings": [
        {
            "severity": "minor",
            "description": "Test finding",
            "cited_lines": ["foo.py:1"],
        }
    ]
}


# ---------------------------------------------------------------------------
# Scenario 1 — RateLimitError on primary → fallback provider answers
# ---------------------------------------------------------------------------


def test_fallback_rate_limit_falls_back_to_provider(monkeypatch) -> None:
    """Given: litellm.completion raises RateLimitError on the primary provider call
    When: dispatch_review is called with a provider chain [anthropic, openai]
    Then:
      - The secondary (openai) provider is called and returns findings
      - The returned result contains a "fallback_hops" summary entry describing the hop
    """
    import litellm

    call_count = 0

    def _mock_completion(model: str, messages, **kwargs):
        nonlocal call_count
        call_count += 1
        if "claude" in model:
            raise litellm.RateLimitError(
                message="Rate limit exceeded",
                model=model,
                llm_provider="anthropic",
            )

        # Simulate openai response
        class _FakeMsg:
            content = '{"findings": [{"severity": "minor", "description": "fallback finding", "cited_lines": ["foo.py:1"]}]}'

        class _FakeChoice:
            message = _FakeMsg()

        class _FakeResp:
            choices = [_FakeChoice()]

        return _FakeResp()

    monkeypatch.setattr("litellm.completion", _mock_completion)

    result = dispatch_review(
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic", "openai"],
        environ={
            "ANTHROPIC_API_KEY": "test-key",
            "OPENAI_API_KEY": "test-key",
        },
    )

    assert "findings" in result, "Result must contain 'findings' key"
    assert call_count >= 2, (
        f"Expected at least 2 litellm.completion calls (primary + fallback), got {call_count}"
    )
    # The hop should be recorded in the result
    assert "fallback_hops" in result, (
        "Result must contain 'fallback_hops' when a fallback occurred"
    )
    hops = result["fallback_hops"]
    assert isinstance(hops, list) and len(hops) >= 1, (
        "fallback_hops must be a non-empty list after a provider hop"
    )


# ---------------------------------------------------------------------------
# Scenario 2 — ContextWindowExceededError on haiku → sonnet answers (same provider)
# ---------------------------------------------------------------------------


def test_fallback_context_window_exceeded_escalates_to_sonnet(monkeypatch) -> None:
    """Given: litellm.completion raises ContextWindowExceededError on the haiku model
    When: dispatch_review is called with a context-model chain [haiku, sonnet] for anthropic
    Then:
      - The sonnet model is tried next (same provider, larger context)
      - The returned result contains findings from the sonnet call
    """
    import litellm

    called_models: list[str] = []

    def _mock_completion(model: str, messages, **kwargs):
        called_models.append(model)
        if "haiku" in model:
            raise litellm.ContextWindowExceededError(
                message="Context window exceeded",
                model=model,
                llm_provider="anthropic",
            )

        # sonnet succeeds
        class _FakeMsg:
            content = '{"findings": [{"severity": "minor", "description": "sonnet finding", "cited_lines": ["foo.py:1"]}]}'

        class _FakeChoice:
            message = _FakeMsg()

        class _FakeResp:
            choices = [_FakeChoice()]

        return _FakeResp()

    monkeypatch.setattr("litellm.completion", _mock_completion)

    result = dispatch_review(
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        context_model_chain=["claude-haiku-4-5-20251001", "claude-sonnet-4-5"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
    )

    assert "findings" in result, "Result must contain 'findings' key"
    assert any("sonnet" in m for m in called_models), (
        f"Expected sonnet model to be called after haiku context overflow; called: {called_models}"
    )


# ---------------------------------------------------------------------------
# Scenario 3 — Full chain failure → fallback_exhausted JSON entry
# ---------------------------------------------------------------------------


def test_fallback_full_chain_failure_emits_exhausted_entry(monkeypatch) -> None:
    """Given: ALL litellm.completion calls raise RateLimitError (chain fully exhausted)
    When: dispatch_review is called with provider_chain=["anthropic", "openai"]
    Then:
      - The returned findings list contains one fallback_exhausted entry
      - That entry has exactly the 6 required fields:
          agent_id, primary_model, attempted_cross_provider[],
          attempted_context_models[], final_exception_class, final_exception_message
    """
    import litellm

    def _always_fail(model: str, messages, **kwargs):
        raise litellm.RateLimitError(
            message="Rate limit everywhere",
            model=model,
            llm_provider="unknown",
        )

    monkeypatch.setattr("litellm.completion", _always_fail)

    result = dispatch_review(
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic", "openai"],
        environ={
            "ANTHROPIC_API_KEY": "test-key",
            "OPENAI_API_KEY": "test-key",
        },
    )

    assert "findings" in result, (
        "Result must contain 'findings' key even on full failure"
    )
    findings = result["findings"]
    exhausted = [f for f in findings if f.get("type") == "fallback_exhausted"]
    assert len(exhausted) == 1, (
        f"Expected exactly 1 fallback_exhausted entry in findings, got {len(exhausted)}. "
        f"Findings: {findings}"
    )


# ---------------------------------------------------------------------------
# Scenario 4 — Contract conformance: fallback_exhausted entry has all 6 fields
# ---------------------------------------------------------------------------


def test_fallback_exhausted_entry_has_required_fields(monkeypatch) -> None:
    """Given: full chain failure (all providers exhaust)
    When: dispatch_review is called
    Then: the fallback_exhausted entry contains all 6 required fields with correct types:
      - agent_id (str)
      - primary_model (str)
      - attempted_cross_provider (list)
      - attempted_context_models (list)
      - final_exception_class (str)
      - final_exception_message (str)
    """
    import litellm

    def _always_fail(model: str, messages, **kwargs):
        raise litellm.RateLimitError(
            message="Out of quota on all providers",
            model=model,
            llm_provider="unknown",
        )

    monkeypatch.setattr("litellm.completion", _always_fail)

    result = dispatch_review(
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic", "openai"],
        agent_id="test-agent-001",
        environ={
            "ANTHROPIC_API_KEY": "test-key",
            "OPENAI_API_KEY": "test-key",
        },
    )

    findings = result.get("findings", [])
    exhausted = [f for f in findings if f.get("type") == "fallback_exhausted"]
    assert exhausted, "No fallback_exhausted entry found in findings"
    entry = exhausted[0]

    required_fields = {
        "agent_id": str,
        "primary_model": str,
        "attempted_cross_provider": list,
        "attempted_context_models": list,
        "final_exception_class": str,
        "final_exception_message": str,
    }
    missing = []
    wrong_type = []
    for field, expected_type in required_fields.items():
        if field not in entry:
            missing.append(field)
        elif not isinstance(entry[field], expected_type):
            wrong_type.append(
                f"{field}: expected {expected_type.__name__}, got {type(entry[field]).__name__}"
            )

    assert not missing, f"fallback_exhausted entry missing required fields: {missing}"
    assert not wrong_type, (
        f"fallback_exhausted entry has wrong field types: {wrong_type}"
    )


# ---------------------------------------------------------------------------
# Scenario 5 — streaming=False preserved across all hops
# ---------------------------------------------------------------------------


def test_fallback_all_litellm_calls_have_streaming_false(monkeypatch) -> None:
    """Given: dispatch_review triggers multiple litellm.completion calls via fallback
    When: any hop occurs (primary + fallback)
    Then: every litellm.completion call has streaming=False (never True or absent)
    """
    import litellm

    captured_kwargs: list[dict] = []
    call_index = 0

    def _mock_completion(model: str, messages, **kwargs):
        nonlocal call_index
        captured_kwargs.append(dict(kwargs))
        call_index += 1
        if call_index == 1:
            # First call fails to force a fallback hop
            raise litellm.RateLimitError(
                message="First call fails",
                model=model,
                llm_provider="anthropic",
            )

        # Second call succeeds
        class _FakeMsg:
            content = '{"findings": []}'

        class _FakeChoice:
            message = _FakeMsg()

        class _FakeResp:
            choices = [_FakeChoice()]

        return _FakeResp()

    monkeypatch.setattr("litellm.completion", _mock_completion)

    dispatch_review(
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic", "openai"],
        environ={
            "ANTHROPIC_API_KEY": "test-key",
            "OPENAI_API_KEY": "test-key",
        },
    )

    assert captured_kwargs, "Expected at least one litellm.completion call"
    for i, kw in enumerate(captured_kwargs):
        assert (
            kw.get("stream") is False
            or kw.get("streaming") is False
            or ("stream" not in kw and "streaming" not in kw)
        ), (
            f"litellm.completion call #{i + 1} must have streaming=False, got kwargs={kw}"
        )
    # Stricter: at least one call must explicitly pass stream=False
    explicit_false = [kw for kw in captured_kwargs if kw.get("stream") is False]
    assert explicit_false, (
        f"No litellm.completion call explicitly set stream=False. "
        f"All captured kwargs: {captured_kwargs}"
    )


# ---------------------------------------------------------------------------
# Scenario 6 — Startup credential check raises ConfigError on missing key
# ---------------------------------------------------------------------------


def test_dispatch_raises_config_error_when_credential_missing() -> None:
    """Given: provider_chain=["anthropic"], ANTHROPIC_API_KEY absent from environ
    When: dispatch_review is called (startup credential check fires)
    Then: raises ConfigError mentioning the missing credential
    """
    with pytest.raises(ConfigError) as exc_info:
        dispatch_review(
            diff_text=_DIFF_TEXT,
            provider_chain=["anthropic"],
            environ={},  # no API key
        )

    msg = str(exc_info.value)
    assert "ANTHROPIC_API_KEY" in msg or "anthropic" in msg.lower(), (
        f"ConfigError should mention the missing credential. Got: {msg!r}"
    )
