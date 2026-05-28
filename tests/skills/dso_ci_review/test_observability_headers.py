"""Tests for Phase 3 observability — Anthropic rate-limit header capture.

Validates extract_anthropic_ratelimit_headers behavior including:
  - Happy path: headers in _hidden_params['additional_headers'] are extracted
  - Defensive WARNING: empty / missing / wrong-shape additional_headers fires
    a one-time WARNING (so a future litellm upgrade is visible in CI logs)
  - Warn-once semantics: the WARNING doesn't spam across multiple calls
  - Integration: _write_usage_entry surfaces the headers in usage entries
"""
from __future__ import annotations

import logging

import pytest

from dso_ci_review.dispatch_ratelimit import (
    extract_anthropic_ratelimit_headers,
    reset_observability_header_warning_for_testing,
)


class _FakeResponse:
    def __init__(self, *, hidden_params=None):
        if hidden_params is not None:
            self._hidden_params = hidden_params


@pytest.fixture(autouse=True)
def _reset_warning_flag():
    """Each test starts with a clean warn-once flag."""
    reset_observability_header_warning_for_testing()
    yield
    reset_observability_header_warning_for_testing()


def test_extracts_anthropic_ratelimit_headers():
    """Happy path: keys prefixed with `anthropic-ratelimit` are extracted."""
    resp = _FakeResponse(
        hidden_params={
            "additional_headers": {
                "llm_provider-anthropic-ratelimit-tokens-remaining": "38500",
                "llm_provider-anthropic-ratelimit-requests-remaining": "47",
                "llm_provider-anthropic-ratelimit-tokens-reset": "2026-05-28T07:00:00Z",
                "llm_provider-anthropic-ratelimit-requests-reset": "2026-05-28T07:01:00Z",
                "llm_provider-request-id": "req_abc",
                "x-ratelimit-remaining-requests": "47",
            }
        }
    )
    extracted = extract_anthropic_ratelimit_headers(resp)
    assert "llm_provider-anthropic-ratelimit-tokens-remaining" in extracted
    assert "llm_provider-anthropic-ratelimit-requests-remaining" in extracted
    assert "llm_provider-anthropic-ratelimit-tokens-reset" in extracted
    assert "llm_provider-anthropic-ratelimit-requests-reset" in extracted
    assert "llm_provider-request-id" not in extracted


def test_missing_hidden_params_warns_once(caplog):
    """No _hidden_params attribute → empty result + one WARNING."""
    resp = object()
    with caplog.at_level(logging.WARNING):
        result = extract_anthropic_ratelimit_headers(resp)
    assert result == {}
    relevant = [r for r in caplog.records if "header shape changed" in r.message]
    assert len(relevant) == 1


def test_empty_additional_headers_warns_once(caplog):
    """additional_headers present but empty → empty result + one WARNING."""
    resp = _FakeResponse(hidden_params={"additional_headers": {}})
    with caplog.at_level(logging.WARNING):
        result = extract_anthropic_ratelimit_headers(resp)
    assert result == {}
    relevant = [r for r in caplog.records if "header shape changed" in r.message]
    assert len(relevant) == 1


def test_additional_headers_without_anthropic_keys_warns_once(caplog):
    """additional_headers present, populated, but no anthropic-ratelimit keys →
    empty result + one WARNING with the available keys listed."""
    resp = _FakeResponse(
        hidden_params={
            "additional_headers": {
                "x-ratelimit-remaining-requests": "47",
                "llm_provider-request-id": "req_abc",
            }
        }
    )
    with caplog.at_level(logging.WARNING):
        result = extract_anthropic_ratelimit_headers(resp)
    assert result == {}
    relevant = [r for r in caplog.records if "header shape changed" in r.message]
    assert len(relevant) == 1


def test_warning_fires_only_once_across_calls(caplog):
    """Multiple bad calls should produce exactly one WARNING."""
    bad = object()
    with caplog.at_level(logging.WARNING):
        for _ in range(5):
            extract_anthropic_ratelimit_headers(bad)
    relevant = [r for r in caplog.records if "header shape changed" in r.message]
    assert len(relevant) == 1


def test_happy_path_does_not_warn(caplog):
    """A successful extraction must NOT trip the WARNING — silent log path."""
    resp = _FakeResponse(
        hidden_params={
            "additional_headers": {
                "llm_provider-anthropic-ratelimit-tokens-remaining": "100",
            }
        }
    )
    with caplog.at_level(logging.WARNING):
        extract_anthropic_ratelimit_headers(resp)
    relevant = [r for r in caplog.records if "header shape changed" in r.message]
    assert relevant == []


def test_hidden_params_wrong_type_warns_once(caplog):
    """If _hidden_params is somehow not a dict, warn and return empty."""
    class _Weird:
        _hidden_params = "not a dict"

    with caplog.at_level(logging.WARNING):
        result = extract_anthropic_ratelimit_headers(_Weird())
    assert result == {}
    relevant = [r for r in caplog.records if "header shape changed" in r.message]
    assert len(relevant) == 1


class TestUsageEntryIntegration:
    """End-to-end: _write_usage_entry attaches anthropic_ratelimit to its
    written entry when the response carries populated additional_headers,
    and omits the field when no anthropic-ratelimit-* headers are present.
    This was claimed by the module docstring but unverified until cycle-3
    verification review caught the gap.
    """

    @staticmethod
    def _capture_entry(captured: dict):
        def _record(entry):
            captured["entry"] = entry

        return _record

    def test_response_with_ratelimit_headers_attaches_field(self):
        from dso_ci_review.dispatch import _write_usage_entry

        class _Usage:
            prompt_tokens = 100
            completion_tokens = 5
            cache_read_input_tokens = 200
            cache_creation_input_tokens = 50

        class _Resp:
            usage = _Usage()
            _hidden_params = {
                "additional_headers": {
                    "llm_provider-anthropic-ratelimit-tokens-remaining": "38500",
                    "llm_provider-anthropic-ratelimit-requests-remaining": "47",
                }
            }

        captured: dict = {}
        from unittest.mock import patch

        with patch(
            "dso_ci_review.dispatch._locked_append_usage_record",
            side_effect=self._capture_entry(captured),
        ):
            _write_usage_entry(
                agent_id="test-agent",
                cycle=1,
                call_index=0,
                model="claude-sonnet-4-5",
                response=_Resp(),
            )

        assert captured.get("entry") is not None, (
            "_write_usage_entry did not delegate to _locked_append_usage_record"
        )
        entry = captured["entry"]
        assert "anthropic_ratelimit" in entry, (
            f"anthropic_ratelimit field missing from entry: {entry}"
        )
        assert (
            entry["anthropic_ratelimit"][
                "llm_provider-anthropic-ratelimit-tokens-remaining"
            ]
            == "38500"
        )
        assert entry["cache_read_input_tokens"] == 200
        assert entry["cache_creation_input_tokens"] == 50

    def test_response_without_ratelimit_headers_omits_field(self):
        from dso_ci_review.dispatch import _write_usage_entry

        class _Usage:
            prompt_tokens = 100
            completion_tokens = 5
            cache_read_input_tokens = None
            cache_creation_input_tokens = None

        class _Resp:
            usage = _Usage()
            _hidden_params = {"additional_headers": {}}

        captured: dict = {}
        from unittest.mock import patch

        with patch(
            "dso_ci_review.dispatch._locked_append_usage_record",
            side_effect=self._capture_entry(captured),
        ):
            _write_usage_entry(
                agent_id="test-agent",
                cycle=1,
                call_index=0,
                model="claude-sonnet-4-5",
                response=_Resp(),
            )

        assert captured.get("entry") is not None
        assert "anthropic_ratelimit" not in captured["entry"], (
            f"anthropic_ratelimit must be omitted when headers absent; "
            f"got {captured['entry']}"
        )

    def test_response_none_omits_ratelimit_field(self):
        from dso_ci_review.dispatch import _write_usage_entry

        captured: dict = {}
        from unittest.mock import patch

        with patch(
            "dso_ci_review.dispatch._locked_append_usage_record",
            side_effect=self._capture_entry(captured),
        ):
            _write_usage_entry(
                agent_id="test-agent",
                cycle=1,
                call_index=0,
                model="claude-sonnet-4-5",
                response=None,
            )

        assert captured.get("entry") is not None
        assert "anthropic_ratelimit" not in captured["entry"]
        assert captured["entry"]["input_tokens"] is None
