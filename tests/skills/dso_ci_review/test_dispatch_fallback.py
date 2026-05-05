"""Tests for dso_ci_review.dispatch fallback chain (DD1–DD5).

Testing mode: UPDATE — tests updated to assert manual context-escalation loop behavior.

DD1: stream=False and fallbacks= passed to litellm.completion (cross-provider, Axis 1).
     context_window_fallbacks= is NOT used — it is a LiteLLM Router parameter silently
     ignored by litellm.completion(). Axis 2 is handled via manual loop instead.

Behavioral contracts under test:
1. litellm.completion called with fallbacks= param for cross-provider fallback
2. ContextWindowExceededError triggers escalation to next model in chain (manual loop, Axis 2)
3. Full chain failure → fallback_exhausted JSON entry (6 required fields)
4. fallback_exhausted JSON validates against expected schema (contract conformance)
5. stream=False preserved; fallbacks= passed explicitly on every litellm.completion call
6. ConfigError raised on startup when provider credential is missing
"""

from __future__ import annotations

import asyncio
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
import dso_ci_review.dispatch as _dispatch_mod  # noqa: E402
from dso_ci_review.dispatch import (  # noqa: E402
    async_dispatch_specialists,
    dispatch_review,
)
from dso_ci_review.providers.config import ConfigError  # noqa: E402


# ---------------------------------------------------------------------------
# Shared test constants
# ---------------------------------------------------------------------------

_DIFF_TEXT = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n"

_PRIMARY_MODEL = "claude-haiku-4-5-20251001"


# ---------------------------------------------------------------------------
# Scenario 1 — litellm.completion called with fallbacks= for cross-provider fallback
# ---------------------------------------------------------------------------


def test_fallback_rate_limit_falls_back_to_provider(monkeypatch) -> None:
    """Given: dispatch_review is called with a provider chain [anthropic, openai]
    When: litellm.completion is called
    Then:
      - litellm.completion is called with a fallbacks= parameter containing the openai model
      - The result contains findings from the successful call
    """
    captured_kwargs: list[dict] = []

    def _mock_completion(model: str, messages, **kwargs):
        captured_kwargs.append(dict(kwargs))

        # Simulate a successful response from the primary provider
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
    assert captured_kwargs, "litellm.completion must be called at least once"

    # DD1: fallbacks= parameter must be passed (SDK-native cross-provider fallback)
    first_call = captured_kwargs[0]
    assert "fallbacks" in first_call, (
        "litellm.completion must be called with fallbacks= parameter for cross-provider fallback. "
        f"Got kwargs keys: {list(first_call.keys())}"
    )
    fallbacks = first_call["fallbacks"]
    assert isinstance(fallbacks, list), (
        f"fallbacks= must be a list, got {type(fallbacks).__name__}"
    )
    # The openai provider should appear in the fallbacks list
    fallback_models = [f.get("model", "") for f in fallbacks if isinstance(f, dict)]
    assert any("gpt" in m or "openai" in m for m in fallback_models), (
        f"Expected openai model in fallbacks list, got: {fallback_models}"
    )


# ---------------------------------------------------------------------------
# Scenario 2 — ContextWindowExceededError escalates to next model in chain (Axis 2)
# ---------------------------------------------------------------------------


def test_fallback_context_window_exceeded_escalates_to_sonnet(monkeypatch) -> None:
    """Given: dispatch_review is called with a context-model chain [haiku, sonnet]
    When: litellm.completion raises ContextWindowExceededError for haiku
    Then:
      - litellm.completion is retried with sonnet (next model in chain)
      - The result contains findings from sonnet
      - fallback_hops is populated indicating context escalation occurred
    """
    import litellm

    call_models: list[str] = []

    def _mock_completion(model: str, messages, **kwargs):
        call_models.append(model)

        if "haiku" in model:
            # Simulate context window exceeded for the small model
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

    # Axis 2: haiku should have been tried first, then sonnet
    assert len(call_models) >= 2, (
        f"Expected at least 2 litellm.completion calls (haiku + sonnet escalation), "
        f"got {len(call_models)}: {call_models}"
    )
    assert any("haiku" in m for m in call_models), (
        f"haiku should have been attempted first; got call sequence: {call_models}"
    )
    assert any("sonnet" in m for m in call_models), (
        f"sonnet should have been tried after haiku failed; got call sequence: {call_models}"
    )

    # DD2: fallback_hops must reflect the context escalation
    assert "fallback_hops" in result, (
        f"fallback_hops must be present when context escalation occurred. "
        f"Result keys: {list(result.keys())}"
    )
    hops = result["fallback_hops"]
    assert isinstance(hops, list) and len(hops) >= 1, (
        f"fallback_hops must be a non-empty list, got: {hops}"
    )
    assert any("sonnet" in h for h in hops), (
        f"fallback_hops should mention sonnet as the escalation target, got: {hops}"
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
# Scenario 5 — stream=False and fallbacks= passed on every litellm.completion call
# ---------------------------------------------------------------------------


def test_fallback_all_litellm_calls_have_streaming_false(monkeypatch) -> None:
    """Given: dispatch_review is called with a two-provider chain
    When: litellm.completion is called
    Then:
      - stream=False is passed explicitly on every call (DD1: never stream)
      - fallbacks= is passed explicitly (DD1: SDK-native cross-provider fallback)
      - context_window_fallbacks= is NOT passed (it is silently ignored by
        litellm.completion; Axis 2 is handled via the manual context escalation loop)
    """
    captured_kwargs: list[dict] = []

    def _mock_completion(model: str, messages, **kwargs):
        captured_kwargs.append(dict(kwargs))

        # Successful response
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

    # All calls must have stream=False explicitly
    for i, kw in enumerate(captured_kwargs):
        assert kw.get("stream") is False, (
            f"litellm.completion call #{i + 1} must explicitly set stream=False, got kwargs={kw}"
        )

    # At least one call must pass fallbacks= (SDK-native cross-provider fallback)
    calls_with_fallbacks = [kw for kw in captured_kwargs if "fallbacks" in kw]
    assert calls_with_fallbacks, (
        f"No litellm.completion call passed fallbacks= parameter. "
        f"All captured kwargs: {captured_kwargs}"
    )

    # context_window_fallbacks= must NOT be passed — it is a LiteLLM Router parameter
    # silently ignored by litellm.completion(); Axis 2 uses a manual loop instead.
    calls_with_ctx_fallbacks = [
        kw for kw in captured_kwargs if "context_window_fallbacks" in kw
    ]
    assert not calls_with_ctx_fallbacks, (
        "litellm.completion must NOT receive context_window_fallbacks= — "
        "this parameter is silently ignored (LiteLLM Router only). "
        "Context escalation is handled by the manual loop in dispatch_review. "
        f"Found calls with the broken parameter: {calls_with_ctx_fallbacks}"
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


# ---------------------------------------------------------------------------
# Scenario 7 — async_dispatch_specialists: partial failure (DD4)
# ---------------------------------------------------------------------------


def test_async_dispatch_partial_failure(monkeypatch) -> None:
    """Given: two agents, one raises, one returns findings
    When: async_dispatch_specialists is called
    Then:
      - The failing agent produces a specialist_error entry in its findings
      - The succeeding agent's findings are intact in the result list
      - Result list has one entry per agent, in input order
    """
    call_count = [0]

    def _mock_completion(model: str, messages, **kwargs):
        call_count[0] += 1

        class _FakeMsg:
            content = '{"findings": [{"severity": "minor", "description": "Good agent finding", "cited_lines": ["foo.py:1"]}]}'

        class _FakeChoice:
            message = _FakeMsg()

        class _FakeResp:
            choices = [_FakeChoice()]

        return _FakeResp()

    monkeypatch.setattr("litellm.completion", _mock_completion)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    # Patch dispatch_review for the failing agent to raise directly
    _orig_dispatch = _dispatch_mod.dispatch_review

    def _patched_dispatch(diff_text, agent_id, primary_model, provider_chain, **kwargs):
        if agent_id == "agent-fail":
            raise RuntimeError("Simulated agent failure")
        return _orig_dispatch(
            diff_text=diff_text,
            agent_id=agent_id,
            primary_model=primary_model,
            provider_chain=provider_chain,
            **kwargs,
        )

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _patched_dispatch)

    agents = [
        {
            "agent_id": "agent-fail",
            "diff_text": _DIFF_TEXT,
            "model": _PRIMARY_MODEL,
            "provider_chain": ["anthropic"],
        },
        {
            "agent_id": "agent-ok",
            "diff_text": _DIFF_TEXT,
            "model": _PRIMARY_MODEL,
            "provider_chain": ["anthropic"],
        },
    ]

    results = asyncio.run(async_dispatch_specialists(agents))

    assert len(results) == 2, f"Expected 2 results (one per agent), got {len(results)}"

    # First result (failing agent) must have a specialist_error entry
    fail_findings = results[0].get("findings", [])
    error_entries = [f for f in fail_findings if f.get("type") == "specialist_error"]
    assert error_entries, (
        f"Expected specialist_error entry for failing agent, got findings: {fail_findings}"
    )
    assert error_entries[0].get("agent_id") == "agent-fail", (
        f"specialist_error should reference agent-fail, got: {error_entries[0]}"
    )

    # Second result (succeeding agent) must have real findings
    ok_findings = results[1].get("findings", [])
    assert ok_findings, f"Expected findings from agent-ok, got: {results[1]}"
    assert ok_findings[0].get("description") == "Good agent finding", (
        f"Expected 'Good agent finding' in ok agent result, got: {ok_findings}"
    )


# ---------------------------------------------------------------------------
# Scenario 8 — async_dispatch_specialists: all succeed (DD4)
# ---------------------------------------------------------------------------


def test_async_dispatch_all_succeed(monkeypatch) -> None:
    """Given: two agents both returning findings
    When: async_dispatch_specialists is called
    Then:
      - Both results contain findings (not error entries)
      - Result list has two entries in input order
    """
    agent_findings: dict[str, str] = {
        "agent-alpha": "Finding from alpha",
        "agent-beta": "Finding from beta",
    }

    def _mock_dispatch(diff_text, agent_id, primary_model, provider_chain, **kwargs):
        description = agent_findings.get(agent_id, "Unknown")
        return {
            "findings": [
                {
                    "severity": "minor",
                    "description": description,
                    "cited_lines": ["foo.py:1"],
                }
            ]
        }

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch)

    agents = [
        {
            "agent_id": "agent-alpha",
            "diff_text": _DIFF_TEXT,
            "model": _PRIMARY_MODEL,
        },
        {
            "agent_id": "agent-beta",
            "diff_text": _DIFF_TEXT,
            "model": _PRIMARY_MODEL,
        },
    ]

    results = asyncio.run(async_dispatch_specialists(agents))

    assert len(results) == 2, f"Expected 2 results, got {len(results)}"

    for i, (result, agent) in enumerate(zip(results, agents)):
        findings = result.get("findings", [])
        assert findings, (
            f"Agent {agent['agent_id']} (index {i}) returned empty findings: {result}"
        )
        error_entries = [f for f in findings if f.get("type") == "specialist_error"]
        assert not error_entries, (
            f"Agent {agent['agent_id']} unexpectedly returned error entry: {error_entries}"
        )

    descriptions = [r["findings"][0]["description"] for r in results]
    assert "Finding from alpha" in descriptions, (
        f"alpha finding missing: {descriptions}"
    )
    assert "Finding from beta" in descriptions, f"beta finding missing: {descriptions}"


# ---------------------------------------------------------------------------
# Scenario 9 — async_dispatch_specialists: empty input (DD4)
# ---------------------------------------------------------------------------


def test_async_dispatch_empty_list() -> None:
    """Given: empty agents list
    When: async_dispatch_specialists is called
    Then: returns empty list without error
    """
    results = asyncio.run(async_dispatch_specialists([]))
    assert results == [], f"Expected empty list for empty input, got: {results}"
