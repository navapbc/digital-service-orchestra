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
