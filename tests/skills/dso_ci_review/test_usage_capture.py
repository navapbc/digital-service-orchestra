"""Tests for review-cycle-usage.json capture in dispatch.py.

Testing mode: RED (story 0801 — usage capture)

Behavioral contracts under test:
1. Happy path: dispatch_review writes a usage entry to review-cycle-usage.json
   using litellm OpenAI-shape (prompt_tokens / completion_tokens).
2. Concurrent writes: 4 parallel dispatch_review calls each produce 1 entry
   (4 total), preserved by fcntl.LOCK_EX read-modify-write.
3. Missing usage: response without .usage attribute does not raise.
4. Exception path: when _parse_response raises, usage entry is written with
   review_outcome='failed' + exception class/message.
"""

from __future__ import annotations

import json
import pathlib
import sys
import threading
from unittest.mock import MagicMock, patch

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.dispatch as _dispatch_mod  # noqa: E402
from dso_ci_review.dispatch import dispatch_review  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_DIFF = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n"
_ANTHROPIC_ENV = {"ANTHROPIC_API_KEY": "test-key"}
_MODEL = "claude-haiku-4-5"

_CANNED_FINDINGS = {
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


def _make_litellm_response(
    *,
    prompt_tokens: int = 100,
    completion_tokens: int = 50,
    cache_read_input_tokens: int = 0,
    cache_creation_input_tokens: int = 10,
    findings: dict | None = None,
    include_usage: bool = True,
) -> MagicMock:
    """Build a minimal litellm-shaped response (OpenAI shape).

    .usage.prompt_tokens / .usage.completion_tokens (not .input_tokens).
    """
    resp = MagicMock()
    resp.choices = [MagicMock()]
    resp.choices[0].message.content = json.dumps(findings or _CANNED_FINDINGS)
    resp._hidden_params = {}

    if include_usage:
        resp.usage = MagicMock()
        # litellm OpenAI-shape
        resp.usage.prompt_tokens = prompt_tokens
        resp.usage.completion_tokens = completion_tokens
        resp.usage.cache_read_input_tokens = cache_read_input_tokens
        resp.usage.cache_creation_input_tokens = cache_creation_input_tokens
    else:
        # Simulate response with no .usage attribute
        del resp.usage

    return resp


# ---------------------------------------------------------------------------
# Test 1: Happy path — usage entry written with litellm-shaped fields
# ---------------------------------------------------------------------------


def test_dispatch_review_writes_usage_json(tmp_path, monkeypatch):
    """Given a successful dispatch_review call with a litellm-shaped response,
    review-cycle-usage.json must contain one entry with:
    - schema_version: '1.0.0'
    - agent_id matching the call
    - input_tokens from response.usage.prompt_tokens
    - output_tokens from response.usage.completion_tokens
    - model field matching ctx_model
    - timestamp_iso present
    """
    monkeypatch.setenv("WORKFLOW_PLUGIN_ARTIFACTS_DIR", str(tmp_path))
    monkeypatch.setenv("DSO_REVIEW_CYCLE", "1")

    fake_response = _make_litellm_response(prompt_tokens=200, completion_tokens=80)

    with patch("litellm.completion", return_value=fake_response):
        result = dispatch_review(
            diff_text=_DIFF,
            provider_chain=["anthropic"],
            environ=_ANTHROPIC_ENV,
            agent_id="code-reviewer-light",
            primary_model=_MODEL,
            tier="light",
        )

    assert "findings" in result

    usage_path = tmp_path / "review-cycle-usage.json"
    assert usage_path.exists(), "review-cycle-usage.json must be created"

    data = json.loads(usage_path.read_text(encoding="utf-8"))
    assert data["schema_version"] == "1.0.0"
    assert isinstance(data["cycles"], list)
    assert len(data["cycles"]) >= 1

    entry = data["cycles"][0]
    assert entry["agent_id"] == "code-reviewer-light"
    assert entry["cycle"] == 1
    assert entry["model"] == _MODEL
    # litellm shape: prompt_tokens → input_tokens
    assert entry["input_tokens"] == 200
    assert entry["output_tokens"] == 80
    assert "timestamp_iso" in entry
    assert entry["timestamp_iso"].endswith("+00:00") or entry["timestamp_iso"].endswith(
        "Z"
    )


# ---------------------------------------------------------------------------
# Test 2: Concurrent writes — 4 parallel calls produce 4 entries
# ---------------------------------------------------------------------------


def test_concurrent_writes_preserved(tmp_path, monkeypatch):
    """4 concurrent dispatch_review calls must each write 1 entry to
    review-cycle-usage.json, resulting in 4 total entries (not 1 due to
    a last-write-wins race).

    Uses threading to simulate asyncio.gather-style concurrency.
    """
    monkeypatch.setenv("WORKFLOW_PLUGIN_ARTIFACTS_DIR", str(tmp_path))
    monkeypatch.setenv("DSO_REVIEW_CYCLE", "2")

    def _make_response(agent_id: str) -> MagicMock:
        return _make_litellm_response(prompt_tokens=50, completion_tokens=20)

    errors: list[Exception] = []
    barrier = threading.Barrier(4)

    def _run(agent_id: str) -> None:
        try:
            fake_response = _make_response(agent_id)

            barrier.wait()  # start all threads simultaneously
            with patch("litellm.completion", return_value=fake_response):
                dispatch_review(
                    diff_text=_DIFF,
                    provider_chain=["anthropic"],
                    environ=_ANTHROPIC_ENV,
                    agent_id=agent_id,
                    primary_model=_MODEL,
                    tier="light",
                )
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    agent_ids = [
        "code-reviewer-light",
        "code-reviewer-standard",
        "code-reviewer-deep-arch",
        "code-reviewer-deep-correctness",
    ]
    threads = [threading.Thread(target=_run, args=(aid,)) for aid in agent_ids]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not errors, f"Thread errors: {errors}"

    usage_path = tmp_path / "review-cycle-usage.json"
    assert usage_path.exists()
    data = json.loads(usage_path.read_text(encoding="utf-8"))
    assert len(data["cycles"]) == 4, (
        f"Expected 4 entries (one per parallel dispatch), got {len(data['cycles'])}: "
        f"{[e['agent_id'] for e in data['cycles']]}"
    )
    written_agents = {e["agent_id"] for e in data["cycles"]}
    assert written_agents == set(agent_ids)


# ---------------------------------------------------------------------------
# Test 3: Missing usage — response without .usage does not raise
# ---------------------------------------------------------------------------


def test_missing_usage_silent(tmp_path, monkeypatch):
    """When the litellm response has no .usage attribute, dispatch_review
    must complete without raising, and the usage entry must still be written
    with input_tokens=None and output_tokens=None.
    """
    monkeypatch.setenv("WORKFLOW_PLUGIN_ARTIFACTS_DIR", str(tmp_path))
    monkeypatch.setenv("DSO_REVIEW_CYCLE", "1")

    fake_response = _make_litellm_response(include_usage=False)

    # Should not raise
    with patch("litellm.completion", return_value=fake_response):
        result = dispatch_review(
            diff_text=_DIFF,
            provider_chain=["anthropic"],
            environ=_ANTHROPIC_ENV,
            agent_id="code-reviewer-light",
            primary_model=_MODEL,
            tier="light",
        )

    assert "findings" in result

    usage_path = tmp_path / "review-cycle-usage.json"
    assert usage_path.exists()
    data = json.loads(usage_path.read_text(encoding="utf-8"))
    assert len(data["cycles"]) >= 1
    entry = data["cycles"][0]
    # When .usage is absent, tokens should be None
    assert entry["input_tokens"] is None
    assert entry["output_tokens"] is None


# ---------------------------------------------------------------------------
# Test 4: Exception path — review_outcome='failed' entry written
# ---------------------------------------------------------------------------


def test_exception_path_writes_failed_entry(tmp_path, monkeypatch):
    """When _parse_response raises after a successful litellm.completion,
    dispatch_review must write a usage entry with review_outcome='failed',
    exception_class, and exception_message.
    """
    monkeypatch.setenv("WORKFLOW_PLUGIN_ARTIFACTS_DIR", str(tmp_path))
    monkeypatch.setenv("DSO_REVIEW_CYCLE", "3")

    # Response that will successfully complete but cause _parse_response to raise
    fake_response = _make_litellm_response()

    def _raise_on_parse(response: object) -> dict:
        raise ValueError("Simulated parse failure")

    with patch("litellm.completion", return_value=fake_response):
        with patch.object(_dispatch_mod, "_parse_response", _raise_on_parse):
            # dispatch_review re-raises after writing the failed entry.
            # The re-raise is caught by the outer `except Exception` handler
            # in the context-window escalation loop, which falls through to the
            # fallback_exhausted return — so dispatch_review returns normally.
            dispatch_review(  # noqa: F841
                diff_text=_DIFF,
                provider_chain=["anthropic"],
                environ=_ANTHROPIC_ENV,
                agent_id="code-reviewer-standard",
                primary_model=_MODEL,
                tier="light",
            )

    # The fallback_exhausted path is triggered, but a failed-outcome entry
    # must have been written to usage.json
    usage_path = tmp_path / "review-cycle-usage.json"
    assert usage_path.exists(), "review-cycle-usage.json must exist even on exception"

    data = json.loads(usage_path.read_text(encoding="utf-8"))
    assert len(data["cycles"]) >= 1

    # Find the entry with review_outcome='failed'
    failed_entries = [e for e in data["cycles"] if e.get("review_outcome") == "failed"]
    assert failed_entries, (
        f"Expected at least one entry with review_outcome='failed'; "
        f"got entries: {[e.get('review_outcome') for e in data['cycles']]}"
    )
    failed = failed_entries[0]
    assert failed["exception_class"] == "ValueError"
    assert "Simulated parse failure" in failed["exception_message"]
    assert failed["agent_id"] == "code-reviewer-standard"
    assert failed["cycle"] == 3
