"""Recurrence-prevention tests for bug f148-2cb6-8b7e-4cdd.

Covers PR-A scope of the multi-PR remediation:
- R1: _resolve_pr_head_sha is event-aware (pull_request → gh, not GITHUB_SHA).
- R2: dispatch chain iterates on ValueError instead of breaking.
- R3: parse failure logs a preview of the raw response on stderr.
- R5: providers/anthropic.py applies the markdown-fenced / preamble rescue.

Each test pins to a fixture under tests/fixtures/llm-review-replay/ when the
input shape matters. Behavioral assertions only — no string-grepping the
source files (instruction-file structural-boundary rule applies to .md
files only; this is .py behavior).
"""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ─── Fixtures ───────────────────────────────────────────────────────────────

FIXTURE_DIR = Path(__file__).parent.parent.parent / "fixtures" / "llm-review-replay"


def _load_fixture(name: str) -> str:
    return (FIXTURE_DIR / name).read_text()


def _mock_response(content: str) -> MagicMock:
    """Build a litellm-shaped response object with the given content."""
    msg = MagicMock()
    msg.content = content
    choice = MagicMock()
    choice.message = msg
    resp = MagicMock()
    resp.choices = [choice]
    return resp


# ─── R1: _resolve_pr_head_sha is event-aware ────────────────────────────────


class TestR1ResolvePrHeadSha:
    """The PR HEAD SHA resolver MUST prefer gh on pull_request events because
    GITHUB_SHA is the synthesized merge-commit ref, not the PR HEAD. The
    Reviews API rejects merge-commit refs with HTTP 422."""

    def test_pull_request_event_prefers_gh_over_github_sha(self, monkeypatch):
        """On pull_request event, gh-resolved SHA must win over GITHUB_SHA."""
        from dso_ci_review.runner import _resolve_pr_head_sha

        monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
        monkeypatch.setenv("GITHUB_SHA", "merge_commit_sha_aaaa")
        with patch("dso_ci_review.runner._gh_pr_head_oid", return_value="real_pr_head_sha_bbbb"):
            result = _resolve_pr_head_sha(442)
        assert result == "real_pr_head_sha_bbbb"

    def test_pull_request_target_event_prefers_gh_over_github_sha(self, monkeypatch):
        from dso_ci_review.runner import _resolve_pr_head_sha

        monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request_target")
        monkeypatch.setenv("GITHUB_SHA", "merge_commit_sha_aaaa")
        with patch("dso_ci_review.runner._gh_pr_head_oid", return_value="real_pr_head_sha_bbbb"):
            result = _resolve_pr_head_sha(442)
        assert result == "real_pr_head_sha_bbbb"

    def test_pull_request_event_falls_back_to_github_sha_with_warning(self, monkeypatch, capsys):
        """When gh fails on a pull_request event, fall back to GITHUB_SHA with
        an explicit warning to stderr (degraded mode)."""
        from dso_ci_review.runner import _resolve_pr_head_sha

        monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
        monkeypatch.setenv("GITHUB_SHA", "fallback_sha_cccc")
        with patch("dso_ci_review.runner._gh_pr_head_oid", return_value=None):
            result = _resolve_pr_head_sha(442)
        assert result == "fallback_sha_cccc"
        captured = capsys.readouterr()
        assert "WARNING" in captured.err
        assert "may 422" in captured.err.lower() or "may be the merge-commit ref" in captured.err

    def test_push_event_uses_github_sha(self, monkeypatch):
        """On push events GITHUB_SHA is the commit being built — use it
        directly without calling gh."""
        from dso_ci_review.runner import _resolve_pr_head_sha

        monkeypatch.setenv("GITHUB_EVENT_NAME", "push")
        monkeypatch.setenv("GITHUB_SHA", "push_sha_dddd")
        # gh must NOT be called; if it is, _gh_pr_head_oid would return None
        # and the test would still pass — assert via mock that it wasn't.
        with patch("dso_ci_review.runner._gh_pr_head_oid") as gh_mock:
            result = _resolve_pr_head_sha(442)
        assert result == "push_sha_dddd"
        gh_mock.assert_not_called()

    def test_workflow_dispatch_event_uses_github_sha(self, monkeypatch):
        from dso_ci_review.runner import _resolve_pr_head_sha

        monkeypatch.setenv("GITHUB_EVENT_NAME", "workflow_dispatch")
        monkeypatch.setenv("GITHUB_SHA", "wd_sha_eeee")
        with patch("dso_ci_review.runner._gh_pr_head_oid") as gh_mock:
            result = _resolve_pr_head_sha(442)
        assert result == "wd_sha_eeee"
        gh_mock.assert_not_called()


# ─── R2: dispatch chain iterates on ValueError ─────────────────────────────


class TestR2FallbackChainIteration:
    """When the LLM call succeeds but returns non-JSON, the dispatch chain
    MUST advance to the next context model rather than `break`ing."""

    def test_chain_advances_to_second_model_on_parse_failure(self):
        """Mock litellm to return non-JSON for the first model, valid JSON
        for the second. Both models must be called.

        ANTHROPIC_API_KEY is set by the autouse fixture in tests/conftest.py
        (_dso_dummy_anthropic_api_key) — no per-test monkeypatch needed.
        """
        import litellm

        from dso_ci_review import dispatch as dispatch_mod

        # Two-model chain: first returns refusal (non-JSON), second returns valid JSON.
        responses = [
            _mock_response(_load_fixture("refusal.txt")),
            _mock_response(json.dumps({"findings": [{"severity": "minor", "description": "ok"}]})),
        ]
        call_log: list[str] = []

        def _fake_completion(*args, **kwargs):
            model = kwargs.get("model", args[0] if args else "?")
            call_log.append(str(model))
            return responses[len(call_log) - 1]

        with patch.object(litellm, "completion", side_effect=_fake_completion):
            result = dispatch_mod.dispatch_review(
                diff_text="dummy diff",
                provider_chain=["anthropic"],
                agent_id="code-reviewer-light",
                tier="light",
                context_model_chain=["claude-haiku-4-5", "claude-sonnet-4-6"],
                primary_model="claude-haiku-4-5",
            )
        # Second model MUST have been called (the chain advanced past the parse failure).
        assert len(call_log) >= 2, (
            f"chain did not advance past ValueError; calls={call_log}"
        )
        # And the valid second-model response must have been returned.
        assert result.get("findings"), f"expected findings from second model; got {result!r}"


# ─── R3: parse failure logs a preview ──────────────────────────────────────


class TestR3ParseFailurePreview:
    """When _parse_response raises ValueError, the stderr log MUST include a
    sanitized preview of the raw_content so operators can diagnose."""

    def test_preview_logged_for_refusal_response(self, capsys):
        from dso_ci_review.dispatch import _parse_response

        with pytest.raises(ValueError):
            _parse_response(_mock_response(_load_fixture("refusal.txt")))
        captured = capsys.readouterr()
        assert "ERROR [preview]:" in captured.err
        # The preview must include identifiable content from the refusal.
        assert "I cannot" in captured.err or "cannot assist" in captured.err

    def test_preview_logged_for_non_json_275_response(self, capsys):
        from dso_ci_review.dispatch import _parse_response

        with pytest.raises(ValueError):
            _parse_response(_mock_response(_load_fixture("non-json-275.txt")))
        captured = capsys.readouterr()
        assert "ERROR [preview]:" in captured.err
        assert "high demand" in captured.err or "I apologize" in captured.err

    def test_preview_is_capped_at_1024_bytes(self, capsys):
        from dso_ci_review.dispatch import _parse_response

        huge = "X" * 5000  # 5 KB of X
        with pytest.raises(ValueError):
            _parse_response(_mock_response(huge))
        captured = capsys.readouterr()
        # The 5000-X preview line must have been truncated.
        preview_line = next(
            (line for line in captured.err.splitlines() if "ERROR [preview]:" in line),
            "",
        )
        # The 1024-byte cap excludes the "ERROR [preview]: " prefix.
        # Check the X-count in the preview is <= 1024.
        x_count = preview_line.count("X")
        assert x_count <= 1024, f"preview not capped; X count was {x_count}"


# ─── R5: providers/anthropic.py applies rescue ─────────────────────────────


class TestR5AnthropicProviderRescue:
    """The legacy providers/anthropic.py adapter MUST apply the same
    _extract_json_from_text rescue that dispatch._parse_response uses, so
    markdown-fenced and friendly-preamble responses succeed instead of
    failing."""

    def test_markdown_fenced_response_is_rescued(self):
        import litellm

        from dso_ci_review.providers.anthropic import review_diff

        fenced = _load_fixture("markdown-fenced.txt")
        with patch.object(litellm, "completion", return_value=_mock_response(fenced)):
            result = review_diff("dummy diff")
        assert isinstance(result, dict)
        assert "findings" in result
        assert isinstance(result["findings"], list)
        assert len(result["findings"]) >= 1

    def test_friendly_preamble_response_is_rescued(self):
        import litellm

        from dso_ci_review.providers.anthropic import review_diff

        preamble = _load_fixture("friendly-preamble.txt")
        with patch.object(litellm, "completion", return_value=_mock_response(preamble)):
            result = review_diff("dummy diff")
        assert isinstance(result, dict)
        assert "findings" in result

    def test_genuine_refusal_still_raises(self):
        """Rescue must NOT mask a genuine non-JSON refusal."""
        import litellm

        from dso_ci_review.providers.anthropic import review_diff

        refusal = _load_fixture("refusal.txt")
        with patch.object(litellm, "completion", return_value=_mock_response(refusal)):
            with pytest.raises(ValueError, match="non-JSON"):
                review_diff("dummy diff")

    def test_clean_json_unchanged_happy_path(self):
        """No regression: clean JSON response still parses normally."""
        import litellm

        from dso_ci_review.providers.anthropic import review_diff

        clean = json.dumps({"findings": [{"severity": "minor", "description": "ok"}]})
        with patch.object(litellm, "completion", return_value=_mock_response(clean)):
            result = review_diff("dummy diff")
        assert result == {"findings": [{"severity": "minor", "description": "ok"}]}


# ─── R5: providers/openai.py applies rescue (parity with anthropic.py) ────────


class TestR5OpenAIProviderRescue:
    """The legacy providers/openai.py adapter MUST apply the same
    _extract_json_from_text rescue that dispatch._parse_response uses, so
    markdown-fenced and empty-findings responses succeed instead of
    failing.  Mirrors TestR5AnthropicProviderRescue exactly but targets
    the openai provider path."""

    def test_markdown_fenced_response_is_rescued(self):
        import litellm

        from dso_ci_review.providers.openai import review_diff

        fenced = _load_fixture("markdown-fenced.txt")
        with patch.object(litellm, "completion", return_value=_mock_response(fenced)):
            result = review_diff("dummy diff")
        assert isinstance(result, dict)
        assert "findings" in result
        assert isinstance(result["findings"], list)
        assert len(result["findings"]) >= 1

    def test_empty_findings_fenced_response_is_rescued(self):
        """CI-failure shape: fenced JSON with empty findings list."""
        import litellm

        from dso_ci_review.providers.openai import review_diff

        fenced = _load_fixture("markdown-fenced-empty-findings.txt")
        with patch.object(litellm, "completion", return_value=_mock_response(fenced)):
            result = review_diff("dummy diff")
        assert isinstance(result, dict)
        assert "findings" in result
        assert result["findings"] == []
        assert result.get("summary") == "No issues found."

    def test_friendly_preamble_response_is_rescued(self):
        import litellm

        from dso_ci_review.providers.openai import review_diff

        preamble = _load_fixture("friendly-preamble.txt")
        with patch.object(litellm, "completion", return_value=_mock_response(preamble)):
            result = review_diff("dummy diff")
        assert isinstance(result, dict)
        assert "findings" in result

    def test_genuine_refusal_still_raises(self):
        """Rescue must NOT mask a genuine non-JSON refusal."""
        import litellm

        from dso_ci_review.providers.openai import review_diff

        refusal = _load_fixture("refusal.txt")
        with patch.object(litellm, "completion", return_value=_mock_response(refusal)):
            with pytest.raises(ValueError, match="non-JSON"):
                review_diff("dummy diff")

    def test_clean_json_unchanged_happy_path(self):
        """No regression: clean JSON response still parses normally."""
        import litellm

        from dso_ci_review.providers.openai import review_diff

        clean = json.dumps({"findings": [{"severity": "minor", "description": "ok"}]})
        with patch.object(litellm, "completion", return_value=_mock_response(clean)):
            result = review_diff("dummy diff")
        assert result == {"findings": [{"severity": "minor", "description": "ok"}]}
