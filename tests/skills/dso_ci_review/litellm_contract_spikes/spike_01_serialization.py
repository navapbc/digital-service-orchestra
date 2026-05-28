"""Spike 01: proves the sync-under-async serialization in dispatch.py.

dispatch.py:1012 (_call_single_agent) is `async def` but its body only calls
synchronous dispatch_review (dispatch.py:455), which calls synchronous
litellm.completion(stream=False). async_dispatch_specialists (dispatch.py:1535)
awaits asyncio.gather over those coroutines — but with no await inside the
coroutine bodies, the event loop cannot interleave them. The "fan-in" is a
no-op; specialists run to completion serially.

This spike replicates the shape with time.sleep and shows three cases:
  A) async def + sync body  → serializes (current production shape)
  B) async def + await body → parallel (post-acompletion migration)
  C) async def + asyncio.to_thread → parallel (fallback migration option)

Re-run whenever the dispatch path or asyncio plumbing is touched, to catch a
regression where someone accidentally re-syncs the call site.
"""
import asyncio
import sys
import time

SLEEP_S = 2.0


async def sync_under_async_specialist(name: str) -> str:
    time.sleep(SLEEP_S)
    return f"{name}-done"


async def true_async_specialist(name: str) -> str:
    await asyncio.sleep(SLEEP_S)
    return f"{name}-done"


def blocking_specialist(name: str) -> str:
    time.sleep(SLEEP_S)
    return f"{name}-done"


async def to_thread_wrapper(name: str) -> str:
    return await asyncio.to_thread(blocking_specialist, name)


async def _gather_case(coro_factory):
    t0 = time.monotonic()
    await asyncio.gather(
        coro_factory("A"), coro_factory("B"), return_exceptions=True
    )
    return time.monotonic() - t0


def main() -> int:
    print(f"Two specialists × {SLEEP_S}s sleep each.")
    print(f"  Expected parallel: ~{SLEEP_S}s | Expected serial: ~{SLEEP_S * 2}s\n")

    elapsed_a = asyncio.run(_gather_case(sync_under_async_specialist))
    elapsed_b = asyncio.run(_gather_case(true_async_specialist))
    elapsed_c = asyncio.run(_gather_case(to_thread_wrapper))

    print(f"Case A — async def + sync body (current code):     {elapsed_a:.3f}s")
    print(f"Case B — async def + await body (acompletion path): {elapsed_b:.3f}s")
    print(f"Case C — async def + asyncio.to_thread (fallback):  {elapsed_c:.3f}s\n")

    serial_threshold = SLEEP_S * 1.8
    parallel_threshold = SLEEP_S * 1.3

    ok = True
    if elapsed_a < serial_threshold:
        print(f"FAIL Case A: expected ≥ {serial_threshold:.3f}s (serialized), got {elapsed_a:.3f}s")
        ok = False
    else:
        print(f"PASS Case A: serialized ({elapsed_a:.3f}s ≥ {serial_threshold:.3f}s) — fatal-flaw shape confirmed")

    if elapsed_b > parallel_threshold:
        print(f"FAIL Case B: expected ≤ {parallel_threshold:.3f}s (parallel), got {elapsed_b:.3f}s")
        ok = False
    else:
        print(f"PASS Case B: parallel ({elapsed_b:.3f}s ≤ {parallel_threshold:.3f}s) — acompletion delivers")

    if elapsed_c > parallel_threshold:
        print(f"FAIL Case C: expected ≤ {parallel_threshold:.3f}s (parallel), got {elapsed_c:.3f}s")
        ok = False
    else:
        print(f"PASS Case C: parallel ({elapsed_c:.3f}s ≤ {parallel_threshold:.3f}s) — to_thread delivers")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
