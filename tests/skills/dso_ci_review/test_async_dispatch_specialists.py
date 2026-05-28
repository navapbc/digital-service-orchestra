"""Tests for async_dispatch_specialists parallelism — Phase 1 regression catcher.

If async_dispatch_specialists ever re-syncs (e.g. via a future refactor that
removes asyncio.to_thread from _call_single_agent), test_parallel_timing will
fail loudly. Sleep-based timing is the only reliable detector of this class
of regression — counting completions cannot distinguish parallel from serial.
"""
from __future__ import annotations

import asyncio
import time
from unittest.mock import patch

import pytest

from dso_ci_review.dispatch import async_dispatch_specialists
from dso_ci_review.dispatch_ratelimit import DispatchContext


SLEEP_S = 0.5


def _slow_sync_dispatch_review(**kwargs):
    """Stand-in for the real dispatch_review — sleeps then returns a benign result."""
    time.sleep(SLEEP_S)
    return {
        "findings": [
            {
                "type": "ok",
                "severity": "minor",
                "category": "correctness",
                "description": f"mock for {kwargs.get('agent_id', '?')}",
                "cited_lines": [],
            }
        ]
    }


@pytest.mark.parametrize("n_agents", [2, 3, 4])
def test_parallel_timing_under_to_thread(n_agents):
    """N agents × SLEEP_S each should complete in ~SLEEP_S, not ~SLEEP_S × N."""
    agents = [
        {
            "agent_id": f"agent_{i}",
            "diff_text": "diff",
            "model": "claude-sonnet-4-5",
            "tier": "light",
        }
        for i in range(n_agents)
    ]

    with patch(
        "dso_ci_review.dispatch.dispatch_review", side_effect=_slow_sync_dispatch_review
    ):
        t0 = time.monotonic()
        results = asyncio.run(async_dispatch_specialists(agents))
        elapsed = time.monotonic() - t0

    assert len(results) == n_agents
    serial = SLEEP_S * n_agents
    parallel_ceiling = SLEEP_S * 1.6
    assert elapsed < parallel_ceiling, (
        f"async_dispatch_specialists serialized: {elapsed:.3f}s ≥ {parallel_ceiling:.3f}s "
        f"(expected ~{SLEEP_S}s for {n_agents} agents). "
        f"asyncio.to_thread wrapping likely regressed."
    )


def test_failure_in_one_agent_does_not_cancel_others():
    """gather(return_exceptions=True) + per-coroutine try/except contract."""
    def _maybe_raise(**kwargs):
        if kwargs.get("agent_id") == "agent_1":
            raise RuntimeError("simulated specialist crash")
        return _slow_sync_dispatch_review(**kwargs)

    agents = [
        {"agent_id": f"agent_{i}", "diff_text": "d", "model": "m", "tier": "light"}
        for i in range(3)
    ]

    with patch(
        "dso_ci_review.dispatch.dispatch_review", side_effect=_maybe_raise
    ):
        results = asyncio.run(async_dispatch_specialists(agents))

    assert len(results) == 3
    assert results[0]["findings"][0]["type"] == "ok"
    assert results[1]["findings"][0]["type"] == "specialist_error"
    assert "simulated specialist crash" in results[1]["findings"][0]["description"]
    assert results[2]["findings"][0]["type"] == "ok"


def test_rate_limit_error_signals_cooldown_on_context():
    """When _call_single_agent catches a 429-shaped exception, the shared
    dispatch_context's cooldown is engaged so siblings/retries gate on it."""

    class _MockRateLimitError(Exception):
        def __init__(self):
            super().__init__("rate limited")
            self.__class__.__name__ = "RateLimitError"
            self.status_code = 429
            # Mirror the litellm.RateLimitError attribute shape we discovered
            # in the spikes — litellm_response_headers carries the headers.
            self.litellm_response_headers = {"retry-after": "1"}

    def _raise_rl(**kwargs):
        raise _MockRateLimitError()

    agents = [{"agent_id": "a", "diff_text": "d", "model": "m", "tier": "light"}]

    async def _flow():
        ctx = DispatchContext.create()
        try:
            await async_dispatch_specialists(agents, dispatch_context=ctx)
            return ctx.cooldown_count
        finally:
            ctx.cleanup()

    with patch("dso_ci_review.dispatch.dispatch_review", side_effect=_raise_rl):
        cooldown_count = asyncio.run(_flow())

    assert cooldown_count == 1, "RateLimitError should engage cooldown exactly once"


def test_non_rate_limit_error_does_not_signal_cooldown():
    """A plain ValueError must not engage the cooldown."""

    def _raise(**kwargs):
        raise ValueError("not a rate limit")

    agents = [{"agent_id": "a", "diff_text": "d", "model": "m", "tier": "light"}]

    async def _flow():
        ctx = DispatchContext.create()
        try:
            await async_dispatch_specialists(agents, dispatch_context=ctx)
            return ctx.cooldown_count
        finally:
            ctx.cleanup()

    with patch("dso_ci_review.dispatch.dispatch_review", side_effect=_raise):
        cooldown_count = asyncio.run(_flow())

    assert cooldown_count == 0


def test_cooldown_gate_actually_delays_dispatch():
    """The cooldown_event.wait() gate at the top of _call_single_agent must
    actually block dispatch when the cooldown is engaged. Cycle-2 verification
    review correctly noted that prior tests used N=1 agent — the gate was a
    no-op (event set at create()) and a regression removing the await line
    would go undetected. This test engages cooldown via the context, then
    dispatches via async_dispatch_specialists and asserts wall-clock delay.
    """
    from dso_ci_review.dispatch import _call_single_agent

    dispatch_invoked_at: dict[str, float] = {}

    def _capture_dispatch_review(**kwargs):
        dispatch_invoked_at["t"] = time.monotonic()
        return {"findings": []}

    async def _flow() -> tuple[float, float]:
        ctx = DispatchContext.create()
        ctx.signal_cooldown(0.3)
        t_start = time.monotonic()
        try:
            with patch(
                "dso_ci_review.dispatch.dispatch_review",
                side_effect=_capture_dispatch_review,
            ):
                await _call_single_agent(
                    agent_id="gated",
                    diff_text="d",
                    model="m",
                    tier="light",
                    dispatch_context=ctx,
                )
        finally:
            ctx.cleanup()
        return t_start, dispatch_invoked_at["t"]

    t_start, t_dispatched = asyncio.run(_flow())
    delay = t_dispatched - t_start
    assert delay >= 0.28, (
        f"Cooldown gate did not delay dispatch: dispatch_review was invoked "
        f"{delay:.3f}s after _call_single_agent entry (expected ≥ 0.30s). "
        f"The `await dispatch_context.cooldown_event.wait()` line at the top "
        f"of _call_single_agent may have regressed."
    )


def test_no_dispatch_context_kwarg_back_compat():
    """Calling without dispatch_context (the existing call sites in runner.py
    and region_split.py) still works — an internal context is created."""
    agents = [
        {"agent_id": "a", "diff_text": "d", "model": "m", "tier": "light"},
        {"agent_id": "b", "diff_text": "d", "model": "m", "tier": "light"},
    ]
    with patch(
        "dso_ci_review.dispatch.dispatch_review", side_effect=_slow_sync_dispatch_review
    ):
        results = asyncio.run(async_dispatch_specialists(agents))
    assert len(results) == 2
