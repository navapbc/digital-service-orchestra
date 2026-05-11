"""Tests for story cade: Anthropic prompt caching with prefix-bytes invariant.

Behavioral contracts under test:
1. _build_messages with provider='anthropic' places cache_control on system and diff.
2. _build_messages with non-Anthropic provider uses plain string content (no cache_control).
3. dispatch_review passes cache_control messages to litellm for Anthropic provider.
4. Stable prefix (first 2 messages) is byte-identical across all augmentation turns.
5. _check_cache_usage logs a warning when cache tokens absent on turn 0.
6. _check_cache_usage logs a warning when cache_read does not increase on turn > 0.
7. _check_cache_usage is a no-op for non-Anthropic providers.
8. Integration: cache-creation observed on turn 0, cache-read observed on turn 1.
"""

from __future__ import annotations

import json
import logging
import pathlib
import sys
from unittest.mock import MagicMock, patch

import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.dispatch import (  # noqa: E402
    _build_messages,
    _check_cache_usage,
    _stable_prefix_hash,
    dispatch_review,
)

_DIFF_TEXT = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n"
_PRIMARY_MODEL = "claude-haiku-4-5-20251001"
_ANTHROPIC_ENV = {"ANTHROPIC_API_KEY": "test-key"}
_OPENAI_ENV = {"OPENAI_API_KEY": "test-key"}


# ---------------------------------------------------------------------------
# Helpers shared across tests
# ---------------------------------------------------------------------------


def _findings_response() -> MagicMock:
    resp = MagicMock()
    resp.choices = [MagicMock()]
    resp.choices[0].message.content = json.dumps(
        {
            "findings": [
                {
                    "severity": "minor",
                    "category": "maintainability",
                    "description": "Example finding",
                    "file": "foo.py",
                    "cited_lines": ["foo.py:1"],
                }
            ],
            "summary": (
                "One minor finding. "
                "security_overlay_warranted: no, performance_overlay_warranted: no"
            ),
        }
    )
    resp.usage = MagicMock()
    resp.usage.cache_creation_input_tokens = 100
    resp.usage.cache_read_input_tokens = 0
    return resp


def _findings_response_with_cache_read() -> MagicMock:
    resp = _findings_response()
    resp.usage.cache_creation_input_tokens = 0
    resp.usage.cache_read_input_tokens = 200
    return resp


def _request_response() -> MagicMock:
    resp = MagicMock()
    resp.choices = [MagicMock()]
    resp.choices[0].message.content = (
        "I need to see the implementation:\n\n"
        "```json\n"
        '{"action": "read_files", "paths": ["foo.py"]}\n'
        "```\n"
    )
    resp.usage = MagicMock()
    resp.usage.cache_creation_input_tokens = 100
    resp.usage.cache_read_input_tokens = 0
    return resp


# ---------------------------------------------------------------------------
# Tests 1–2: _build_messages cache_control placement
# ---------------------------------------------------------------------------


class TestBuildMessagesAnthropicCacheControl:
    """_build_messages with provider='anthropic' places cache_control breakpoints."""

    def test_system_message_has_ephemeral_cache_control(self) -> None:
        """Given: provider='anthropic'
        When: _build_messages is called
        Then: system message content is a list with an ephemeral cache_control block
        """
        msgs = _build_messages(
            _DIFF_TEXT, agent_id="code-reviewer-light", provider="anthropic"
        )
        sys_msg = msgs[0]
        assert sys_msg["role"] == "system"
        assert isinstance(sys_msg["content"], list), (
            "Anthropic system message content must be a list of content blocks"
        )
        cache_controls = [
            blk.get("cache_control", {}).get("type")
            for blk in sys_msg["content"]
            if isinstance(blk, dict)
        ]
        assert "ephemeral" in cache_controls, (
            f"System message must have cache_control type='ephemeral'; got: {sys_msg['content']!r}"
        )

    def test_diff_message_has_ephemeral_cache_control(self) -> None:
        """Given: provider='anthropic'
        When: _build_messages is called
        Then: user (diff) message content is a list with an ephemeral cache_control block
        """
        msgs = _build_messages(
            _DIFF_TEXT, agent_id="code-reviewer-light", provider="anthropic"
        )
        user_msg = msgs[1]
        assert user_msg["role"] == "user"
        assert isinstance(user_msg["content"], list), (
            "Anthropic user message content must be a list of content blocks"
        )
        cache_controls = [
            blk.get("cache_control", {}).get("type")
            for blk in user_msg["content"]
            if isinstance(blk, dict)
        ]
        assert "ephemeral" in cache_controls, (
            f"Diff message must have cache_control type='ephemeral'; got: {user_msg['content']!r}"
        )

    def test_diff_text_preserved_in_content_block(self) -> None:
        """Diff text is embedded in the text field, not lost in the content block."""
        msgs = _build_messages(
            _DIFF_TEXT, agent_id="code-reviewer-light", provider="anthropic"
        )
        user_blocks = msgs[1]["content"]
        combined_text = " ".join(
            blk.get("text", "") for blk in user_blocks if isinstance(blk, dict)
        )
        assert _DIFF_TEXT in combined_text, (
            "Diff text must be preserved in the user content block text field"
        )


class TestBuildMessagesNonAnthropicNoCache:
    """_build_messages with non-Anthropic providers uses plain string content."""

    @pytest.mark.parametrize("provider", ["openai", "unknown", "azure"])
    def test_openai_uses_string_content(self, provider: str) -> None:
        """Given: provider is not 'anthropic'
        When: _build_messages is called
        Then: both messages use plain string content (no content-block list)
        """
        msgs = _build_messages(
            _DIFF_TEXT, agent_id="code-reviewer-light", provider=provider
        )
        for msg in msgs:
            assert isinstance(msg["content"], str), (
                f"Non-Anthropic provider '{provider}' message content must be a string; "
                f"got: {type(msg['content']).__name__!r} for role={msg['role']!r}"
            )


# ---------------------------------------------------------------------------
# Test 3: dispatch_review passes cache_control messages to litellm
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "tier",
    ["standard", "deep"],
    ids=["standard", "deep"],
)
class TestDispatchPassesCacheControlForAnthropic:
    """dispatch_review passes cache_control messages to litellm for Anthropic provider."""

    def test_anthropic_completion_receives_content_block_messages(
        self, tier: str, tmp_path: pathlib.Path
    ) -> None:
        """Given: provider_chain=['anthropic'] with tier=standard or deep
        When: dispatch_review is called
        Then: litellm.completion receives messages where system/user content are lists
        """
        (tmp_path / "foo.py").write_text("x = 1\n")
        captured_messages: list[list] = []

        def mock_completion(**kwargs):
            captured_messages.append(kwargs["messages"])
            return _findings_response()

        with patch("litellm.completion", side_effect=mock_completion):
            dispatch_review(
                diff_text=_DIFF_TEXT,
                provider_chain=["anthropic"],
                primary_model=_PRIMARY_MODEL,
                repo_root=str(tmp_path),
                tier=tier,
                agent_id="code-reviewer-light",
                environ=_ANTHROPIC_ENV,
            )

        assert captured_messages, "litellm.completion was never called"
        first_call_msgs = captured_messages[0]
        sys_msg = next((m for m in first_call_msgs if m["role"] == "system"), None)
        user_msg = next((m for m in first_call_msgs if m["role"] == "user"), None)
        assert sys_msg is not None, "No system message in first completion call"
        assert user_msg is not None, "No user message in first completion call"
        assert isinstance(sys_msg["content"], list), (
            f"tier={tier}: Anthropic system message must use content blocks"
        )
        assert isinstance(user_msg["content"], list), (
            f"tier={tier}: Anthropic user message must use content blocks"
        )

    def test_augmentation_follow_up_turns_omit_cache_control(
        self, tier: str, tmp_path: pathlib.Path
    ) -> None:
        """Follow-up augmentation-loop messages must NOT carry cache_control.

        The cached prefix is the first 2 messages (system + diff). Subsequent
        user messages that carry file-read results are dynamic per-turn — adding
        cache_control to them would bust the stable prefix and defeat caching.
        """
        if tier == "deep":
            pytest.skip(
                "deep tier uses a different multi-agent path; tested separately"
            )

        (tmp_path / "foo.py").write_text("x = 1\n")
        all_captured: list[list] = []
        call_count = 0

        def mock_completion(**kwargs):
            nonlocal call_count
            call_count += 1
            all_captured.append(kwargs["messages"])
            if call_count == 1:
                return _request_response()
            return _findings_response()

        with (
            patch("litellm.completion", side_effect=mock_completion),
            patch(
                "dso_ci_review.context_request.execute_read_files",
                return_value="=== foo.py ===\nx = 1\n",
            ),
        ):
            dispatch_review(
                diff_text=_DIFF_TEXT,
                provider_chain=["anthropic"],
                primary_model=_PRIMARY_MODEL,
                repo_root=str(tmp_path),
                tier="standard",
                agent_id="code-reviewer-light",
                environ=_ANTHROPIC_ENV,
            )

        assert len(all_captured) >= 2, (
            "Expected at least 2 completion calls (initial + augmentation turn)"
        )
        # First call: system + diff messages — these carry cache_control.
        # Second call onward: the new messages appended per turn must NOT carry cache_control.
        first_msgs = all_captured[0]
        second_msgs = all_captured[1]
        # Identify which messages are new in the second call (not in the first).
        new_messages = second_msgs[len(first_msgs) :]
        assert new_messages, "Expected new messages appended in augmentation turn"
        for msg in new_messages:
            content = msg.get("content", "")
            if isinstance(content, list):
                for blk in content:
                    if isinstance(blk, dict):
                        assert "cache_control" not in blk, (
                            f"Augmentation-turn message must not carry cache_control; "
                            f"found it in role={msg['role']!r} block: {blk!r}"
                        )

    def test_openai_completion_receives_string_messages(
        self, tier: str, tmp_path: pathlib.Path
    ) -> None:
        """Given: provider_chain=['openai'] with tier=standard or deep
        When: dispatch_review is called
        Then: litellm.completion receives messages with plain string content
        """
        (tmp_path / "foo.py").write_text("x = 1\n")
        captured_messages: list[list] = []

        def mock_completion(**kwargs):
            captured_messages.append(kwargs["messages"])
            return _findings_response()

        with patch("litellm.completion", side_effect=mock_completion):
            dispatch_review(
                diff_text=_DIFF_TEXT,
                provider_chain=["openai"],
                primary_model="openai/gpt-4o-mini",
                repo_root=str(tmp_path),
                tier=tier,
                agent_id="code-reviewer-light",
                environ=_OPENAI_ENV,
            )

        assert captured_messages, "litellm.completion was never called"
        first_call_msgs = captured_messages[0]
        for msg in first_call_msgs:
            if msg["role"] in ("system", "user"):
                assert isinstance(msg["content"], str), (
                    f"tier={tier}: OpenAI {msg['role']} message content must be a string; "
                    f"got: {type(msg['content']).__name__!r}"
                )


# ---------------------------------------------------------------------------
# Test 4: Prefix-bytes-hash invariant across augmentation turns
# ---------------------------------------------------------------------------


class TestPrefixBytesHashInvariant:
    """Stable prefix (first 2 messages) must be byte-identical across all turns."""

    def test_prefix_hash_stable_across_augmentation_turns(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: augmentation loop with multiple turns
        When: messages are captured at each litellm.completion call
        Then: first 2 messages (system + diff) are byte-identical on every turn
        """
        (tmp_path / "foo.py").write_text("x = 1\n")
        captured_prefixes: list[str] = []

        call_count = 0

        def mock_completion(**kwargs):
            nonlocal call_count
            call_count += 1
            msgs = kwargs["messages"]
            prefix_hash = _stable_prefix_hash(msgs)
            captured_prefixes.append(prefix_hash)
            if call_count == 1:
                return _request_response()
            return _findings_response()

        with patch("litellm.completion", side_effect=mock_completion):
            dispatch_review(
                diff_text=_DIFF_TEXT,
                provider_chain=["anthropic"],
                primary_model=_PRIMARY_MODEL,
                repo_root=str(tmp_path),
                tier="standard",
                agent_id="code-reviewer-light",
                soft_cap=5,
                environ=_ANTHROPIC_ENV,
            )

        assert len(captured_prefixes) >= 2, (
            "Expected at least 2 completion calls for prefix invariant check"
        )
        first_hash = captured_prefixes[0]
        for i, h in enumerate(captured_prefixes[1:], 1):
            assert h == first_hash, (
                f"Stable prefix hash changed on turn {i}: "
                f"expected {first_hash!r}, got {h!r}. "
                "Per-turn dynamic content must not drift into the cached prefix."
            )

    def test_stable_prefix_hash_deterministic(self) -> None:
        """_stable_prefix_hash returns the same value for the same message list."""
        msgs = _build_messages(
            _DIFF_TEXT, agent_id="code-reviewer-light", provider="anthropic"
        )
        h1 = _stable_prefix_hash(msgs)
        h2 = _stable_prefix_hash(msgs)
        assert h1 == h2, "_stable_prefix_hash must be deterministic"

    def test_stable_prefix_hash_changes_on_diff_change(self) -> None:
        """_stable_prefix_hash produces a different hash when diff content changes."""
        msgs_a = _build_messages(
            "diff text A", agent_id="code-reviewer-light", provider="anthropic"
        )
        msgs_b = _build_messages(
            "diff text B", agent_id="code-reviewer-light", provider="anthropic"
        )
        assert _stable_prefix_hash(msgs_a) != _stable_prefix_hash(msgs_b), (
            "Different diff content must produce different prefix hashes"
        )


# ---------------------------------------------------------------------------
# Tests 5–7: _check_cache_usage warning behavior
# ---------------------------------------------------------------------------


class TestCheckCacheUsageWarnings:
    """_check_cache_usage logs warnings on cache misses."""

    def _make_response(self, cache_creation: int, cache_read: int) -> MagicMock:
        resp = MagicMock()
        resp.usage = MagicMock()
        resp.usage.cache_creation_input_tokens = cache_creation
        resp.usage.cache_read_input_tokens = cache_read
        return resp

    def test_warns_on_turn_0_when_both_cache_tokens_zero(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Given: turn=0, cache_creation=0, cache_read=0
        When: _check_cache_usage is called
        Then: warning is logged about cache miss
        """
        resp = self._make_response(cache_creation=0, cache_read=0)
        with caplog.at_level(logging.WARNING, logger="dso_ci_review.dispatch"):
            _check_cache_usage(resp, turn=0, prev_cache_read=None, provider="anthropic")
        assert any("cache miss" in r.message.lower() for r in caplog.records), (
            "Expected a cache-miss warning on turn 0 with zero cache tokens"
        )

    def test_no_warning_on_turn_0_when_cache_creation_present(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Given: turn=0, cache_creation=100, cache_read=0
        When: _check_cache_usage is called
        Then: no warning logged (cache warming in progress is normal)
        """
        resp = self._make_response(cache_creation=100, cache_read=0)
        with caplog.at_level(logging.WARNING, logger="dso_ci_review.dispatch"):
            _check_cache_usage(resp, turn=0, prev_cache_read=None, provider="anthropic")
        cache_miss_warnings = [
            r for r in caplog.records if "cache miss" in r.message.lower()
        ]
        assert not cache_miss_warnings, (
            f"No cache-miss warning expected when cache_creation > 0; got: {cache_miss_warnings}"
        )

    def test_no_warning_on_turn_0_when_cache_read_present(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Given: turn=0, cache_creation=0, cache_read=200 (CI-retry cache-warm state)
        When: _check_cache_usage is called
        Then: no warning logged (cache-warm CI retry is legitimate)
        """
        resp = self._make_response(cache_creation=0, cache_read=200)
        with caplog.at_level(logging.WARNING, logger="dso_ci_review.dispatch"):
            _check_cache_usage(resp, turn=0, prev_cache_read=None, provider="anthropic")
        cache_miss_warnings = [
            r for r in caplog.records if "cache miss" in r.message.lower()
        ]
        assert not cache_miss_warnings, (
            "No cache-miss warning expected when cache_read > 0 (CI-retry tolerance)"
        )

    def test_warns_when_cache_read_does_not_increase_on_subsequent_turn(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Given: turn=1, prev_cache_read=200, cache_read=200 (no increase)
        When: _check_cache_usage is called
        Then: warning logged about stable prefix invalidation
        """
        resp = self._make_response(cache_creation=0, cache_read=200)
        with caplog.at_level(logging.WARNING, logger="dso_ci_review.dispatch"):
            _check_cache_usage(resp, turn=1, prev_cache_read=200, provider="anthropic")
        assert any("cache_read_input_tokens" in r.message for r in caplog.records), (
            "Expected warning about cache_read not increasing on turn > 0"
        )

    def test_no_warning_when_cache_read_increases(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Given: turn=1, prev_cache_read=100, cache_read=300 (increasing)
        When: _check_cache_usage is called
        Then: no warning logged
        """
        resp = self._make_response(cache_creation=0, cache_read=300)
        with caplog.at_level(logging.WARNING, logger="dso_ci_review.dispatch"):
            _check_cache_usage(resp, turn=1, prev_cache_read=100, provider="anthropic")
        assert not caplog.records, (
            f"No warning expected when cache_read increases; got: {[r.message for r in caplog.records]}"
        )

    def test_noop_for_non_anthropic_provider(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Given: provider='openai'
        When: _check_cache_usage is called
        Then: returns None, no warnings logged (OpenAI prefix caching is automatic)
        """
        resp = self._make_response(cache_creation=0, cache_read=0)
        with caplog.at_level(logging.WARNING, logger="dso_ci_review.dispatch"):
            result = _check_cache_usage(
                resp, turn=0, prev_cache_read=None, provider="openai"
            )
        assert result is None, "Non-Anthropic provider must return None"
        assert not caplog.records, "No warnings expected for non-Anthropic provider"

    def test_returns_none_when_response_has_no_usage_attribute(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Given: provider='anthropic', response with no .usage attribute
        When: _check_cache_usage is called
        Then: returns None with no warnings or side effects (early-return path)
        """

        class _NoUsageResponse:
            """Minimal response object with no .usage attribute at all."""

        resp = _NoUsageResponse()
        assert not hasattr(resp, "usage"), "Test fixture must not have .usage attribute"
        with caplog.at_level(logging.WARNING, logger="dso_ci_review.dispatch"):
            result = _check_cache_usage(
                resp, turn=0, prev_cache_read=None, provider="anthropic"
            )
        assert result is None, (
            "_check_cache_usage must return None when response has no .usage attribute"
        )
        assert not caplog.records, (
            "No warnings expected when response.usage is absent (early-return path); "
            f"got: {[r.message for r in caplog.records]}"
        )


# ---------------------------------------------------------------------------
# Test 8: Integration — cache-creation on turn 1, cache-read on turn 2
# ---------------------------------------------------------------------------


class TestCacheHitIntegration:
    """Integration: cache-creation observed on first call, cache-read on second call."""

    def test_cache_creation_on_turn_0_cache_read_on_turn_1(
        self, tmp_path: pathlib.Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Given: augmentation loop where turn 0 creates cache, turn 1 reads it
        When: dispatch_review runs with standard tier
        Then: no cache-miss warnings (cache creation on turn 0, cache read on turn 1)
        """
        (tmp_path / "foo.py").write_text("x = 1\n")
        call_count = 0

        def mock_completion(**kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                # Turn 0: cache warming
                return _request_response()  # has cache_creation=100, cache_read=0
            # Turn 1: cache hit
            return (
                _findings_response_with_cache_read()
            )  # cache_creation=0, cache_read=200

        with caplog.at_level(logging.WARNING, logger="dso_ci_review.dispatch"):
            with patch("litellm.completion", side_effect=mock_completion):
                dispatch_review(
                    diff_text=_DIFF_TEXT,
                    provider_chain=["anthropic"],
                    primary_model=_PRIMARY_MODEL,
                    repo_root=str(tmp_path),
                    tier="standard",
                    agent_id="code-reviewer-light",
                    soft_cap=5,
                    environ=_ANTHROPIC_ENV,
                )

        cache_miss_warnings = [
            r for r in caplog.records if "cache miss" in r.message.lower()
        ]
        assert not cache_miss_warnings, (
            f"No cache-miss warnings expected when cache_creation on turn 0 "
            f"and cache_read on turn 1; got: {[r.message for r in cache_miss_warnings]}"
        )
        assert call_count >= 2, (
            "Expected at least 2 completion calls for this integration scenario"
        )
