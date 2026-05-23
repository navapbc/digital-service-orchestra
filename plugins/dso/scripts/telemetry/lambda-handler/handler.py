import json
import os
from validator import validate_event
from privacy import apply_server_side_privacy
from s3_writer import write_to_s3


def lambda_handler(event, context, _s3_client=None):
    body_str = event.get("body")
    if not body_str:
        return {"statusCode": 400, "body": "Missing body"}
    try:
        payload = json.loads(body_str)
    except (json.JSONDecodeError, TypeError):
        return {"statusCode": 400, "body": "Invalid JSON"}
    valid, err = validate_event(payload)
    if not valid:
        return {"statusCode": 400, "body": err}
    sanitized = apply_server_side_privacy(payload)
    bucket = os.environ["TELEMETRY_BUCKET"]
    write_to_s3(sanitized, bucket, s3_client=_s3_client)
    return {"statusCode": 202, "body": ""}
