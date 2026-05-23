"""
End-to-end tests for the Lambda handler against the canonical schema.

Schema: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/telemetry-event-schema.md (schema_version=1)
"""

import json
from unittest.mock import Mock

import pytest

from handler import lambda_handler


# Canonical review_finding payload (most field-heavy event type — exercises
# the cited_excerpt privacy gate end-to-end).
BASE_PAYLOAD = {
    "schema_version": 1,
    "event_id": "a1b2c3d4-e5f6-4789-abcd-ef0123456789",
    "event_type": "review_finding",
    "client_id": "other-client",
    "tool_id": "dso",
    "tool_version": "1.17.11",
    "timestamp": "2026-05-22T14:30:00Z",
    "finding_id": "f-a1b2c3d4",
    "severity": "important",
    "category": "correctness",
    "description": "Off-by-one in index arithmetic.",
    "file": "src/processor.py",
    "cited_lines": ["src/processor.py:42"],
    "cited_excerpt": "secret",
}


@pytest.fixture(autouse=True)
def set_bucket_env(monkeypatch):
    monkeypatch.setenv("TELEMETRY_BUCKET", "test-bucket")


def _make_event(payload):
    return {"body": json.dumps(payload)}


def test_lambda_handler_returns_202_and_puts_object():
    mock_s3 = Mock()
    resp = lambda_handler(_make_event(BASE_PAYLOAD), None, _s3_client=mock_s3)
    assert resp["statusCode"] == 202
    mock_s3.put_object.assert_called_once()


def test_lambda_handler_malformed_json_returns_400_no_s3():
    mock_s3 = Mock()
    resp = lambda_handler({"body": "not-json"}, None, _s3_client=mock_s3)
    assert resp["statusCode"] == 400
    assert resp["body"]
    mock_s3.put_object.assert_not_called()


def test_lambda_handler_no_body_returns_400_no_s3():
    mock_s3 = Mock()
    resp = lambda_handler({}, None, _s3_client=mock_s3)
    assert resp["statusCode"] == 400
    assert resp["body"]
    mock_s3.put_object.assert_not_called()


def test_lambda_handler_schema_invalid_returns_400_no_s3():
    mock_s3 = Mock()
    payload = {**BASE_PAYLOAD, "severity": "blocker"}  # not in canonical enum
    resp = lambda_handler(_make_event(payload), None, _s3_client=mock_s3)
    assert resp["statusCode"] == 400
    assert resp["body"]
    mock_s3.put_object.assert_not_called()


def test_lambda_handler_unknown_event_type_returns_400():
    mock_s3 = Mock()
    payload = {**BASE_PAYLOAD, "event_type": "made_up_type"}
    resp = lambda_handler(_make_event(payload), None, _s3_client=mock_s3)
    assert resp["statusCode"] == 400
    mock_s3.put_object.assert_not_called()


def test_lambda_handler_privacy_strips_excerpt_body():
    # Non-dso-self client_id and emit_excerpts not True → cited_excerpt stripped.
    mock_s3 = Mock()
    lambda_handler(_make_event(BASE_PAYLOAD), None, _s3_client=mock_s3)
    body = json.loads(mock_s3.put_object.call_args.kwargs["Body"])
    assert body["cited_excerpt"] is None


def test_lambda_handler_dso_self_preserves_excerpt_body():
    # client_id == 'dso-self' → cited_excerpt preserved.
    mock_s3 = Mock()
    payload = {**BASE_PAYLOAD, "client_id": "dso-self"}
    lambda_handler(_make_event(payload), None, _s3_client=mock_s3)
    body = json.loads(mock_s3.put_object.call_args.kwargs["Body"])
    assert body["cited_excerpt"] == "secret"


def test_lambda_handler_emit_excerpts_override_preserves_body():
    # emit_excerpts is True (boolean identity) → cited_excerpt preserved even
    # for non-dso-self client_id.
    mock_s3 = Mock()
    payload = {**BASE_PAYLOAD, "emit_excerpts": True}
    lambda_handler(_make_event(payload), None, _s3_client=mock_s3)
    body = json.loads(mock_s3.put_object.call_args.kwargs["Body"])
    assert body["cited_excerpt"] == "secret"
