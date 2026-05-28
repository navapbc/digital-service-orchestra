"""Spike 02: probes whether litellm.completion retries internally on 429.

The earlier plan proposed setting litellm.num_retries = 0 at module import to
suppress retry amplification (per HKUDS/nanobot #2511). This spike checks
whether that knob is actually needed against the pinned litellm version
(plugins/dso/scripts/pyproject.toml).

Mocks httpx.Client.send to always return 429 with Retry-After: 1. Counts
invocations across four configurations:
  Test 1: default config (no num_retries kwarg)
  Test 2: num_retries=0 explicit kwarg
  Test 3: num_retries=3 explicit kwarg (sanity check the knob works)
  Test 4: module-level litellm.num_retries = 0

If Test 1 invocation count is 1 → no hidden retry → the knob is unnecessary.
If > 1 → litellm amplifies on its own → MUST set num_retries=0.

Empirically validated against litellm 1.83.7 (production pin): Test 1 = 1.
Knob unnecessary. Re-run on every litellm bump.

Note: Test 3 with num_retries=3 may raise "tenacity import failed" if tenacity
isn't installed — that's litellm's actual retry implementation, opt-in and
dependency-gated. Confirms there is no other hidden retry path.
"""
import json
import os
import sys
from unittest.mock import patch

os.environ.setdefault("LITELLM_LOG", "ERROR")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-ant-fake-for-test")

import httpx  # noqa: E402
import litellm  # noqa: E402


_call_count = {"n": 0}


def _mock_429(*_args, **_kwargs):
    _call_count["n"] += 1
    return httpx.Response(
        status_code=429,
        headers={"retry-after": "1"},
        content=json.dumps(
            {"error": {"type": "rate_limit_error", "message": "Rate limit exceeded"}}
        ).encode(),
        request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"),
    )


def _run_one(label: str, **kwargs) -> int:
    _call_count["n"] = 0
    with patch("httpx.Client.send", side_effect=_mock_429):
        try:
            litellm.completion(
                model="anthropic/claude-sonnet-4-5",
                messages=[{"role": "user", "content": "test"}],
                **kwargs,
            )
        except Exception as exc:
            kind = type(exc).__name__
            print(f"  {label} raised: {kind}: {str(exc)[:60]}")
    print(f"  {label} HTTP invocations: {_call_count['n']}")
    return _call_count["n"]


def main() -> int:
    print(f"litellm.num_retries module default: {litellm.num_retries}\n")

    print("Test 1: default config (no num_retries kwarg)")
    n1 = _run_one("Test 1")

    print("\nTest 2: num_retries=0 explicit kwarg")
    n2 = _run_one("Test 2", num_retries=0)

    print("\nTest 3: num_retries=3 explicit kwarg (sanity check)")
    n3 = _run_one("Test 3", num_retries=3)

    print("\nTest 4: module-level litellm.num_retries = 0")
    litellm.num_retries = 0
    n4 = _run_one("Test 4")

    print("\n=== VERDICT ===")
    if n1 == 1:
        print(f"PASS: default config makes 1 HTTP call (no hidden retry). The")
        print(f"      `litellm.num_retries = 0` knob is unnecessary on this version.")
        ok = True
    else:
        print(f"FAIL: default config made {n1} HTTP calls — hidden retry amplification.")
        print(f"      The plan MUST set litellm.num_retries = 0.")
        ok = False

    if n2 != 1 or n4 != 1:
        print(f"      (n2={n2}, n4={n4} — explicit num_retries=0 should give 1)")
        ok = False

    print(f"\nSummary: n1={n1}, n2={n2}, n3={n3}, n4={n4}")
    print("If Test 3 raised 'tenacity import failed', litellm retries are opt-in")
    print("AND dependency-gated — confirms no other hidden retry path.")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
