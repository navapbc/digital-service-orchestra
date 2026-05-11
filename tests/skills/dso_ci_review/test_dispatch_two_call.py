"""RED tests for dso_ci_review.dispatch.dispatch_two_call_review.

Testing mode: RED — dispatch_two_call_review does not yet exist in dispatch.py.
Both tests MUST fail with AttributeError before implementation.

Behavioral contracts under test:
1. Call 1 receives prior_findings_index (no defense_text); Call 2 receives full
   prior_findings + defenses (including defense_text).
2. Call 2 receives Call 1 output; function returns a dict with a "findings" key.
"""

from __future__ import annotations

import json
import sys
import pathlib
from unittest.mock import patch


# Ensure the plugin scripts directory is on sys.path so that
# `dso_ci_review.dispatch` resolves to the plugin source, not the test package.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.dispatch as _dispatch_mod  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_fake_response(findings_json: dict):
    """Build a minimal fake litellm response whose .choices[0].message.content
    is a JSON-serialised findings dict."""

    class _FakeMsg:
        content = json.dumps(findings_json)

    class _FakeChoice:
        message = _FakeMsg()

    class _FakeResp:
        choices = [_FakeChoice()]

    return _FakeResp()


# ---------------------------------------------------------------------------
# Test 1: Call 1 receives index (no defense_text); Call 2 receives full data
# ---------------------------------------------------------------------------


def test_call1_receives_index_not_defense_text():
    """Given:
      prior_findings_index = [{"id": "f1", "cited_lines": ["src/foo.py:10"],
                                "dimension": "correctness"}]
      prior_findings       = [{"id": "f1", "cited_lines": ["src/foo.py:10"],
                                "defense_text": "SECRET", "dimension": "correctness"}]
      defenses             = [{"prior_finding_id": "f1", "defense_text": "SECRET"}]
      Mock LLM returns valid findings JSON for both calls.
    When: dispatch_two_call_review called
    Then:
      - LLM was called TWICE (2 invocations)
      - Call 1 message content does NOT contain "SECRET"
      - Call 2 message content DOES contain "SECRET"
    """
    prior_findings_index = [
        {"id": "f1", "cited_lines": ["src/foo.py:10"], "dimension": "correctness"}
    ]
    prior_findings = [
        {
            "id": "f1",
            "cited_lines": ["src/foo.py:10"],
            "defense_text": "SECRET",
            "dimension": "correctness",
        }
    ]
    defenses = [{"prior_finding_id": "f1", "defense_text": "SECRET"}]

    call1_response = _make_fake_response(
        {
            "findings": [
                {
                    "finding_id": "f-call1",
                    "severity": "minor",
                    "description": "call1 finding",
                    "cited_lines": [],
                }
            ]
        }
    )
    call2_response = _make_fake_response(
        {
            "findings": [
                {
                    "finding_id": "f-call2",
                    "severity": "minor",
                    "description": "call2 finding",
                    "cited_lines": [],
                }
            ]
        }
    )

    captured_calls: list[dict] = []

    def _mock_completion(model, messages, **kwargs):
        # Capture the full messages list for each call
        captured_calls.append({"model": model, "messages": messages, "kwargs": kwargs})
        if len(captured_calls) == 1:
            return call1_response
        return call2_response

    with patch("dso_ci_review.dispatch.litellm", create=True) as mock_litellm:
        mock_litellm.completion.side_effect = _mock_completion
        # Also patch ContextWindowExceededError so the import in dispatch_review works
        mock_litellm.ContextWindowExceededError = Exception

        _dispatch_mod.dispatch_two_call_review(
            diff_text="--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x=1\n+x=2\n",
            prior_findings_index=prior_findings_index,
            prior_findings=prior_findings,
            defenses=defenses,
            provider_chain=["anthropic"],
            environ={"ANTHROPIC_API_KEY": "test-key"},
            agent_id="code-reviewer-standard",
            primary_model="claude-haiku-4-5-20251001",
        )

    # Assert LLM was called exactly twice
    assert mock_litellm.completion.call_count == 2, (
        f"Expected 2 LLM calls, got {mock_litellm.completion.call_count}"
    )

    # Serialize Call 1 messages to a string for content inspection
    call1_content = json.dumps(captured_calls[0]["messages"])
    call2_content = json.dumps(captured_calls[1]["messages"])

    # Call 1 must NOT expose defense_text
    assert "SECRET" not in call1_content, (
        "Call 1 must NOT contain defense_text ('SECRET') — "
        "only the index (no defense_text) should be passed to Call 1."
    )

    # Call 2 MUST include defense_text
    assert "SECRET" in call2_content, (
        "Call 2 must contain defense_text ('SECRET') — "
        "full prior_findings + defenses should be passed to Call 2."
    )


# ---------------------------------------------------------------------------
# Test 2: Call 2 receives Call 1 output; function returns findings dict
# ---------------------------------------------------------------------------


def test_call2_receives_call1_output():
    """Given:
      Call 1 returns {"findings": [{"finding_id": "f-new", "severity": "minor", ...}]}
      prior_findings = [{"id": "f1", "cited_lines": [], "dimension": "correctness"}]
      defenses = []
    When: dispatch_two_call_review called
    Then:
      - Call 2 message content includes the Call 1 findings output (f-new finding text)
      - The function returns a dict with a "findings" key
    """
    prior_findings = [{"id": "f1", "cited_lines": [], "dimension": "correctness"}]
    defenses: list[dict] = []

    call1_findings = {
        "findings": [
            {
                "finding_id": "f-new",
                "severity": "minor",
                "description": "initial review finding",
                "cited_lines": ["src/bar.py:42"],
            }
        ]
    }
    call2_findings = {
        "findings": [
            {
                "finding_id": "f-final",
                "severity": "minor",
                "description": "consolidated finding",
                "cited_lines": ["src/bar.py:42"],
            }
        ]
    }

    call1_response = _make_fake_response(call1_findings)
    call2_response = _make_fake_response(call2_findings)

    captured_calls: list[dict] = []

    def _mock_completion(model, messages, **kwargs):
        captured_calls.append({"model": model, "messages": messages})
        if len(captured_calls) == 1:
            return call1_response
        return call2_response

    with patch("dso_ci_review.dispatch.litellm", create=True) as mock_litellm:
        mock_litellm.completion.side_effect = _mock_completion
        mock_litellm.ContextWindowExceededError = Exception

        result = _dispatch_mod.dispatch_two_call_review(
            diff_text="--- a/bar.py\n+++ b/bar.py\n@@ -1 +1 @@\n-y=1\n+y=2\n",
            prior_findings_index=prior_findings,
            prior_findings=prior_findings,
            defenses=defenses,
            provider_chain=["anthropic"],
            environ={"ANTHROPIC_API_KEY": "test-key"},
            agent_id="code-reviewer-standard",
            primary_model="claude-haiku-4-5-20251001",
        )

    # Call 2 must receive Call 1's output
    assert len(captured_calls) == 2, f"Expected 2 LLM calls, got {len(captured_calls)}"
    call2_content = json.dumps(captured_calls[1]["messages"])
    assert "f-new" in call2_content, (
        "Call 2 messages must include Call 1's findings output ('f-new' finding id)."
    )

    # Function must return a dict with a "findings" key
    assert isinstance(result, dict), f"Expected dict result, got {type(result)}"
    assert "findings" in result, (
        f"Result must contain 'findings' key; got keys: {list(result.keys())}"
    )
