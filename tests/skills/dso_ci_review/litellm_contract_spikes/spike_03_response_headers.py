"""Spike 03: verifies Anthropic rate-limit headers and cache tokens are reachable.

Phase 3 (observability) of the parallelization plan reads:
  - anthropic-ratelimit-tokens-remaining / -requests-remaining / -tokens-reset
  - cache_read_input_tokens / cache_creation_input_tokens

This spike mocks an Anthropic 200 response carrying those headers and usage
fields, then inspects the litellm ModelResponse to confirm the access path.

Empirically validated against litellm 1.83.7 (production pin):
  - Headers reachable via response._hidden_params["additional_headers"],
    keys prefixed `llm_provider-anthropic-ratelimit-`.
  - Cache tokens reachable as direct attributes of response.usage.
  - return_response_headers=True kwarg works but is NOT required; headers
    are populated by default.

Re-run on every litellm bump. If the access path changes, Phase 3 must
follow — failure prints the actual shape so the new path is visible.
"""
import json
import os
import sys
from unittest.mock import patch

os.environ.setdefault("LITELLM_LOG", "ERROR")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-ant-fake-for-test")

import httpx  # noqa: E402
import litellm  # noqa: E402


ANTHROPIC_BODY = {
    "id": "msg_test",
    "type": "message",
    "role": "assistant",
    "model": "claude-sonnet-4-5",
    "content": [{"type": "text", "text": "ok"}],
    "stop_reason": "end_turn",
    "stop_sequence": None,
    "usage": {
        "input_tokens": 100,
        "output_tokens": 5,
        "cache_creation_input_tokens": 50,
        "cache_read_input_tokens": 200,
    },
}

ANTHROPIC_HEADERS = {
    "anthropic-ratelimit-requests-limit": "50",
    "anthropic-ratelimit-requests-remaining": "47",
    "anthropic-ratelimit-requests-reset": "2026-05-28T07:00:00Z",
    "anthropic-ratelimit-tokens-limit": "40000",
    "anthropic-ratelimit-tokens-remaining": "38500",
    "anthropic-ratelimit-tokens-reset": "2026-05-28T07:01:00Z",
    "anthropic-ratelimit-input-tokens-remaining": "39500",
    "anthropic-ratelimit-output-tokens-remaining": "9000",
    "request-id": "req_abc123",
    "content-type": "application/json",
}


def _mock_response(*_args, **_kwargs):
    return httpx.Response(
        status_code=200,
        headers=ANTHROPIC_HEADERS,
        content=json.dumps(ANTHROPIC_BODY).encode(),
        request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"),
    )


def main() -> int:
    with patch("httpx.Client.send", side_effect=_mock_response):
        resp = litellm.completion(
            model="anthropic/claude-sonnet-4-5",
            messages=[{"role": "user", "content": "test"}],
        )

    ok = True

    cache_read = getattr(resp.usage, "cache_read_input_tokens", None)
    cache_creation = getattr(resp.usage, "cache_creation_input_tokens", None)
    print(f"usage.cache_read_input_tokens: {cache_read}")
    print(f"usage.cache_creation_input_tokens: {cache_creation}")
    if cache_read != 200 or cache_creation != 50:
        print("FAIL: cache token fields not reachable as expected.")
        ok = False
    else:
        print("PASS: cache tokens reachable on response.usage")

    print()
    hidden = getattr(resp, "_hidden_params", None)
    if not isinstance(hidden, dict):
        print(f"FAIL: response._hidden_params missing or wrong type: {type(hidden).__name__}")
        return 1
    additional = hidden.get("additional_headers", {})
    if not additional:
        print("FAIL: _hidden_params['additional_headers'] empty or missing")
        return 1

    anthropic_keys = [k for k in additional if "anthropic-ratelimit" in k]
    print(f"Anthropic-ratelimit keys found: {len(anthropic_keys)}")
    required = [
        "llm_provider-anthropic-ratelimit-tokens-remaining",
        "llm_provider-anthropic-ratelimit-requests-remaining",
        "llm_provider-anthropic-ratelimit-tokens-reset",
        "llm_provider-anthropic-ratelimit-requests-reset",
    ]
    missing = [k for k in required if k not in additional]
    if missing:
        print(f"FAIL: missing required keys: {missing}")
        print(f"      Available keys: {sorted(additional.keys())}")
        ok = False
    else:
        print(f"PASS: all 4 required headers reachable via _hidden_params['additional_headers']")
        for k in required:
            print(f"      {k} = {additional[k]}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
