import json
import os
from unittest.mock import Mock
import pytest
from handler import lambda_handler

BASE_PAYLOAD = {
    "event_id": "e1", "timestamp": "2024-01-01T00:00:00Z", "client_id": "other",
    "session_id": "s1", "epic_id": "ep1", "story_id": "st1",
    "reviewer_id": "r1", "verdict": "PASS", "score": 5,
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
    payload = {**BASE_PAYLOAD, "verdict": "INVALID_VERDICT"}
    resp = lambda_handler(_make_event(payload), None, _s3_client=mock_s3)
    assert resp["statusCode"] == 400
    assert resp["body"]
    mock_s3.put_object.assert_not_called()


def test_lambda_handler_privacy_strips_excerpt_body():
    # dd-3: non-dso-self without emit_excerpts=True -> cited_excerpt stripped
    mock_s3 = Mock()
    lambda_handler(_make_event(BASE_PAYLOAD), None, _s3_client=mock_s3)
    body = json.loads(mock_s3.put_object.call_args.kwargs["Body"])
    assert body["cited_excerpt"] is None


def test_lambda_handler_dso_self_preserves_excerpt_body():
    # dd-4: dso-self -> cited_excerpt preserved
    mock_s3 = Mock()
    payload = {**BASE_PAYLOAD, "client_id": "dso-self"}
    lambda_handler(_make_event(payload), None, _s3_client=mock_s3)
    body = json.loads(mock_s3.put_object.call_args.kwargs["Body"])
    assert body["cited_excerpt"] == "secret"


def test_lambda_handler_emit_excerpts_override_preserves_body():
    # dd-5: emit_excerpts is True (boolean identity) -> cited_excerpt preserved
    mock_s3 = Mock()
    payload = {**BASE_PAYLOAD, "emit_excerpts": True}
    lambda_handler(_make_event(payload), None, _s3_client=mock_s3)
    body = json.loads(mock_s3.put_object.call_args.kwargs["Body"])
    assert body["cited_excerpt"] == "secret"
