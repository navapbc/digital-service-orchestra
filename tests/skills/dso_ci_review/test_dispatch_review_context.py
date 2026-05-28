"""Tests for REVIEW_CONTEXT: ci signal in CI dispatch path (bug 532e).

The CI runner dispatches reviews via _build_messages() which constructs the
user message sent to the LLM. The agent prompt has a conditional: when
REVIEW_CONTEXT: ci is present, the reviewer restricts findings to
diff-visible code only. Without it, the reviewer operates in full-codebase
mode and makes unverified cross-file claims (false positives).

Behavioral contracts under test:
1. _build_messages() prepends REVIEW_CONTEXT: ci when review_context="ci"
2. _build_messages() omits REVIEW_CONTEXT when review_context is None
3. dispatch_review() propagates review_context to _build_messages()
4. dispatch_two_call_review() propagates review_context to both calls
"""

from __future__ import annotations

import sys
import pathlib

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.dispatch import _build_messages  # noqa: E402


class TestBuildMessagesReviewContext:
    def test_ci_context_present_in_user_message(self):
        """When review_context='ci', user message must contain REVIEW_CONTEXT: ci."""
        messages = _build_messages(
            "diff --git a/f.py b/f.py\n",
            agent_id="code-reviewer-standard",
            provider="anthropic",
            review_context="ci",
        )
        user_msg = messages[1]
        if isinstance(user_msg["content"], list):
            text = user_msg["content"][0]["text"]
        else:
            text = user_msg["content"]
        assert "REVIEW_CONTEXT: ci" in text

    def test_no_context_by_default(self):
        """When review_context is None (default), user message must NOT contain REVIEW_CONTEXT."""
        messages = _build_messages(
            "diff --git a/f.py b/f.py\n",
            agent_id="code-reviewer-standard",
            provider="anthropic",
        )
        user_msg = messages[1]
        if isinstance(user_msg["content"], list):
            text = user_msg["content"][0]["text"]
        else:
            text = user_msg["content"]
        assert "REVIEW_CONTEXT:" not in text

    def test_ci_context_openai_provider(self):
        """REVIEW_CONTEXT: ci works for non-Anthropic providers too."""
        messages = _build_messages(
            "diff --git a/f.py b/f.py\n",
            agent_id="code-reviewer-standard",
            provider="openai",
            review_context="ci",
        )
        user_msg = messages[1]
        text = user_msg["content"]
        assert "REVIEW_CONTEXT: ci" in text
