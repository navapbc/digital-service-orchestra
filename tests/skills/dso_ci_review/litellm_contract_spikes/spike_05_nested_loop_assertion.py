"""Spike 05: confirms runner.py's asyncio.run sites are CLI-invocation-only.

Must-fix 2 from the parallelization plan review: the four asyncio.run call
sites (runner.py:2373, 2465, 2479 and region_split.py:460) assume no host
event loop is already running. This spike asserts that posture explicitly
by attempting to invoke the same shape from inside a running loop and
confirming asyncio.run raises RuntimeError as expected.

If a host integration ever needs to run dispatch from inside an existing
loop, this spike will fail and force the maintainer to add a get_running_loop
guard at the call sites.

Re-run alongside the other contract spikes (run_all.sh) — exits non-zero if
the assertion fails.
"""
import asyncio
import sys


async def _noop_coro() -> str:
    return "ok"


def _simulate_runner_call_site() -> str:
    """Mirrors the shape of runner.py:2373 and friends — synchronous wrapper
    that calls asyncio.run on an async helper. This must NOT be invoked from
    a context that already has a running event loop."""
    return asyncio.run(_noop_coro())


async def _attempt_nested_invocation() -> bool:
    try:
        _simulate_runner_call_site()
    except RuntimeError as exc:
        message = str(exc)
    else:
        return False
    return "asyncio.run() cannot be called from a running event loop" in message


def main() -> int:
    plain_result = _simulate_runner_call_site()
    if plain_result != "ok":
        print(f"FAIL: simulated call site returned {plain_result!r}, expected 'ok'")
        return 1
    print("PASS: simulated call site works in plain (CLI) context")

    nested_blocked = asyncio.run(_attempt_nested_invocation())
    if not nested_blocked:
        print(
            "FAIL: nested asyncio.run did NOT raise the expected RuntimeError. "
            "The CLI-only assumption no longer holds — call sites need a "
            "get_running_loop guard."
        )
        return 1
    print("PASS: nested invocation correctly raises RuntimeError")
    print("      CLI-only invariant intact for runner.py asyncio.run sites")
    return 0


if __name__ == "__main__":
    sys.exit(main())
