"""Spike 04: confirms litellm.acompletion parallelizes under asyncio.gather.

The whole parallelization plan hinges on migrating dispatch_review from
litellm.completion (sync) to litellm.acompletion (async). This spike proves
that two acompletion calls awaited concurrently actually run in parallel,
and that the same headers/usage fields surface on the async path.

Empirically validated against litellm 1.83.7 (production pin):
  - Two acompletion calls × 1s mock latency complete in ~1.01s (parallel),
    not ~2s (serial).
  - response._hidden_params["additional_headers"] populated under async path,
    matching the sync path's shape.

Re-run on every litellm bump.
"""
import asyncio
import json
import os
import sys
import time
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
    "anthropic-ratelimit-tokens-remaining": "38500",
    "anthropic-ratelimit-requests-remaining": "47",
    "content-type": "application/json",
}

MOCK_LATENCY_S = 1.0


async def _slow_async_response(*_args, **_kwargs):
    await asyncio.sleep(MOCK_LATENCY_S)
    return httpx.Response(
        status_code=200,
        headers=ANTHROPIC_HEADERS,
        content=json.dumps(ANTHROPIC_BODY).encode(),
        request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"),
    )


async def _run() -> int:
    if not callable(getattr(litellm, "acompletion", None)):
        print("FAIL: litellm.acompletion not callable")
        return 1
    print("PASS: litellm.acompletion is callable\n")

    with patch("httpx.AsyncClient.send", side_effect=_slow_async_response):
        resp = await litellm.acompletion(
            model="anthropic/claude-sonnet-4-5",
            messages=[{"role": "user", "content": "test"}],
        )

    hidden = getattr(resp, "_hidden_params", {})
    additional = hidden.get("additional_headers", {})
    has_anthropic = any("anthropic-ratelimit" in k for k in additional)
    print(f"Async path surfaces anthropic-ratelimit headers: {has_anthropic}")
    if not has_anthropic:
        print(f"FAIL: no anthropic-ratelimit keys in _hidden_params['additional_headers']")
        print(f"      Available: {sorted(additional.keys())}")
        return 1

    with patch("httpx.AsyncClient.send", side_effect=_slow_async_response):
        t0 = time.monotonic()
        results = await asyncio.gather(
            litellm.acompletion(
                model="anthropic/claude-sonnet-4-5",
                messages=[{"role": "user", "content": "a"}],
            ),
            litellm.acompletion(
                model="anthropic/claude-sonnet-4-5",
                messages=[{"role": "user", "content": "b"}],
            ),
            return_exceptions=True,
        )
        elapsed = time.monotonic() - t0

    serial = MOCK_LATENCY_S * 2
    parallel_threshold = MOCK_LATENCY_S * 1.5
    print(f"\nTwo acompletion calls × {MOCK_LATENCY_S}s mock latency")
    print(f"  Expected parallel: ~{MOCK_LATENCY_S}s | Serial: ~{serial}s")
    print(f"  Elapsed: {elapsed:.3f}s")
    print(f"  Results: {[type(r).__name__ for r in results]}")

    if elapsed > parallel_threshold:
        print(f"FAIL: elapsed {elapsed:.3f}s > {parallel_threshold:.3f}s — acompletion serialized")
        return 1
    print(f"PASS: parallel ({elapsed:.3f}s ≤ {parallel_threshold:.3f}s)")
    return 0


def main() -> int:
    return asyncio.run(_run())


if __name__ == "__main__":
    sys.exit(main())
