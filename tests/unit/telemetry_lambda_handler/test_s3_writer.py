import json
from unittest.mock import Mock
from s3_writer import write_to_s3

EVENT = {
    "event_id": "evt-42",
    "client_id": "acme",
    "timestamp": "2020-01-15T10:00:00Z",
    "verdict": "PASS",
}


def test_write_to_s3_puts_correct_key_and_body():
    mock_s3 = Mock()
    write_to_s3(EVENT, "my-bucket", s3_client=mock_s3)
    mock_s3.put_object.assert_called_once()
    call_kwargs = mock_s3.put_object.call_args.kwargs
    assert call_kwargs["Bucket"] == "my-bucket"
    assert call_kwargs["Key"] == "acme/2020-01-15/evt-42.jsonl"
    body = json.loads(call_kwargs["Body"])
    assert body["event_id"] == "evt-42"


def test_write_to_s3_date_from_timestamp_not_now():
    # Historical timestamp proves date comes from event, not datetime.now()
    mock_s3 = Mock()
    write_to_s3({**EVENT, "timestamp": "2015-06-30T12:00:00Z", "event_id": "old"}, "b", s3_client=mock_s3)
    key = mock_s3.put_object.call_args.kwargs["Key"]
    assert "2015-06-30" in key
