import json
from datetime import datetime, timezone


def write_to_s3(event: dict, bucket: str, s3_client=None) -> None:
    if s3_client is None:
        import boto3
        s3_client = boto3.client("s3")
    ts = event["timestamp"].replace("Z", "+00:00")
    date_str = datetime.fromisoformat(ts).date().isoformat()
    key = f"{event['client_id']}/{date_str}/{event['event_id']}.jsonl"
    body = json.dumps(event).encode("utf-8")
    s3_client.put_object(Bucket=bucket, Key=key, Body=body)
