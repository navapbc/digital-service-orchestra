"""Tests for story 592a: tier wiring of the context-augmentation loop.

Behavioral contracts under test:
1. Light tier: dispatch_review() does NOT enter the augmentation loop (single-shot).
2. Standard tier: dispatch_review() DOES enter the augmentation loop when the LLM
   issues a context-request block.
3. All non-light reviewer agent prompt files contain a reference to the context-request
   contract doc (docs/contracts/ci-review-context-request.md).
4. The light-tier agent prompt explicitly states context-requests are NOT available.
"""

from __future__ import annotations

import json
import pathlib
import sys
from unittest.mock import MagicMock, patch

import pytest

# Ensure plugin scripts dir is on sys.path before importing from the plugin.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.dispatch import dispatch_review  # noqa: E402

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

_DIFF_TEXT = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n"
_PRIMARY_MODEL = "claude-haiku-4-5-20251001"

_AGENTS_DIR = _REPO_ROOT / "plugins" / "dso" / "agents"
_CONTRACT_REF = "docs/contracts/ci-review-context-request.md"

# Standard/deep/overlay reviewer agent files (non-light)
_NON_LIGHT_AGENT_FILES = [
    _AGENTS_DIR / "code-reviewer-standard.md",
    _AGENTS_DIR / "code-reviewer-deep-arch.md",
    _AGENTS_DIR / "code-reviewer-deep-correctness.md",
    _AGENTS_DIR / "code-reviewer-deep-hygiene.md",
    _AGENTS_DIR / "code-reviewer-deep-verification.md",
    _AGENTS_DIR / "code-reviewer-performance.md",
    _AGENTS_DIR / "code-reviewer-security-blue-team.md",
    _AGENTS_DIR / "code-reviewer-security-red-team.md",
    _AGENTS_DIR / "code-reviewer-test-quality.md",
]
_LIGHT_AGENT_FILE = _AGENTS_DIR / "code-reviewer-light.md"


def _findings_response() -> MagicMock:
    """Return a mock litellm response with a well-formed findings JSON (no request block)."""
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
    return resp


def _request_response() -> MagicMock:
    """Return a mock litellm response with a read_files context-request block."""
    resp = MagicMock()
    resp.choices = [MagicMock()]
    resp.choices[0].message.content = (
        "I need to see the implementation:\n\n"
        "```json\n"
        '{"action": "read_files", "paths": ["foo.py"]}\n'
        "```\n"
    )
    return resp


# ---------------------------------------------------------------------------
# Test 1: Light tier does NOT enter the augmentation loop
# ---------------------------------------------------------------------------


def test_light_tier_dispatch_skips_augmentation_loop(tmp_path: pathlib.Path) -> None:
    """dispatch_review(tier='light') issues exactly ONE litellm.completion call.

    The multi-turn augmentation loop is guarded by `if tier != 'light'`.  Even when
    the mock returns a context-request block the loop is never entered, so the
    dispatcher treats the response as final and returns after a single call.
    """
    call_count = 0

    def mock_completion(**kwargs):
        nonlocal call_count
        call_count += 1
        # Return a request block — this should be IGNORED for light tier.
        return _request_response()

    (tmp_path / "foo.py").write_text("x = 1\n")
    diff_file = tmp_path / "test.diff"
    diff_file.write_text(_DIFF_TEXT)

    with patch("litellm.completion", side_effect=mock_completion), patch(
        "dso_ci_review.context_request.execute_read_files"
    ) as mock_execute_read_files:
        dispatch_review(
            diff_text=_DIFF_TEXT,
            provider_chain=["anthropic"],
            primary_model=_PRIMARY_MODEL,
            repo_root=str(tmp_path),
            tier="light",
            environ={"ANTHROPIC_API_KEY": "test-key"},
        )

    assert call_count == 1, (
        f"Light tier must issue exactly 1 completion call; got {call_count}. "
        "The augmentation loop must not be entered for tier='light'."
    )
    assert mock_execute_read_files.call_count == 0, (
        f"execute_read_files must never be called for light tier; "
        f"got {mock_execute_read_files.call_count} call(s). "
        "The context-request block in the response must be ignored entirely."
    )


# ---------------------------------------------------------------------------
# Test 2: Standard tier DOES enter the augmentation loop
# ---------------------------------------------------------------------------


def test_standard_tier_dispatch_enters_augmentation_loop(
    tmp_path: pathlib.Path,
) -> None:
    """dispatch_review(tier='standard') enters the augmentation loop when the LLM
    issues a context-request block, resulting in more than one completion call.
    """
    call_count = 0

    def mock_completion(**kwargs):
        nonlocal call_count
        call_count += 1
        # First call: return a request block to trigger the loop.
        # Second call: return final findings.
        if call_count == 1:
            return _request_response()
        return _findings_response()

    (tmp_path / "foo.py").write_text("x = 1\n")

    with patch("litellm.completion", side_effect=mock_completion):
        dispatch_review(
            diff_text=_DIFF_TEXT,
            provider_chain=["anthropic"],
            primary_model=_PRIMARY_MODEL,
            repo_root=str(tmp_path),
            tier="standard",
            soft_cap=5,
            environ={"ANTHROPIC_API_KEY": "test-key"},
        )

    assert call_count > 1, (
        f"Standard tier must issue more than 1 completion call when LLM requests "
        f"context; got {call_count}. The augmentation loop must be entered for "
        "tier='standard'."
    )


# ---------------------------------------------------------------------------
# Test 3: Deep-tier dispatch also enters the augmentation loop
# ---------------------------------------------------------------------------


def test_deep_tier_dispatch_enters_augmentation_loop(tmp_path: pathlib.Path) -> None:
    """dispatch_review(tier='deep') enters the augmentation loop (same guard as standard)."""
    call_count = 0

    def mock_completion(**kwargs):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return _request_response()
        return _findings_response()

    (tmp_path / "foo.py").write_text("x = 1\n")

    with patch("litellm.completion", side_effect=mock_completion):
        dispatch_review(
            diff_text=_DIFF_TEXT,
            provider_chain=["anthropic"],
            primary_model=_PRIMARY_MODEL,
            repo_root=str(tmp_path),
            tier="deep",
            soft_cap=5,
            environ={"ANTHROPIC_API_KEY": "test-key"},
        )

    assert call_count > 1, (
        f"Deep tier must enter the augmentation loop; got {call_count} calls."
    )


# ---------------------------------------------------------------------------
# Test 4: Non-light agent prompt files contain the contract reference
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("agent_file", _NON_LIGHT_AGENT_FILES, ids=lambda p: p.name)
def test_non_light_agent_prompts_contain_contract_reference(
    agent_file: pathlib.Path,
) -> None:
    """Every non-light reviewer agent prompt must reference the context-request contract."""
    assert agent_file.exists(), (
        f"Agent file not found: {agent_file}. Run build-review-agents.sh to regenerate."
    )
    content = agent_file.read_text(encoding="utf-8")
    assert _CONTRACT_REF in content, (
        f"{agent_file.name} must contain a reference to '{_CONTRACT_REF}'. "
        "The context-request availability section is missing from this agent prompt."
    )


# ---------------------------------------------------------------------------
# Test 5: Light agent prompt explicitly states context-requests are NOT available
# ---------------------------------------------------------------------------


def test_light_agent_prompt_states_context_requests_unavailable() -> None:
    """The light-tier agent prompt must explicitly state that context-requests are
    not available (not just omit the section).
    """
    assert _LIGHT_AGENT_FILE.exists(), (
        f"Light agent file not found: {_LIGHT_AGENT_FILE}. "
        "Run build-review-agents.sh to regenerate."
    )
    content = _LIGHT_AGENT_FILE.read_text(encoding="utf-8")

    # Must reference the contract (so agents know what they're opting out of)
    assert _CONTRACT_REF in content, (
        f"Light agent prompt must still reference '{_CONTRACT_REF}' "
        "(even though context-requests are unavailable — agents need to know the contract)."
    )

    # Must clearly state unavailability
    unavailability_signals = [
        "NOT available for light tier",
        "not available for light tier",
        "does NOT enter the",
        "single-shot",
    ]
    found = any(sig in content for sig in unavailability_signals)
    assert found, (
        f"Light agent prompt must explicitly state context-requests are not available. "
        f"Looked for one of: {unavailability_signals!r}"
    )
