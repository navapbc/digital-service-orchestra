"""Tests for dispatch_ratelimit module — parallelization plan Phase 1.

Coverage:
  - parse_retry_after: ms / seconds / HTTP-date / malformed / missing
  - calculate_backoff: server-supplied within cap / clamped / exponential / jitter range
  - should_retry: 429 / 5xx / 4xx / x-should-retry header
  - DispatchContext: cooldown gates wait, TimerHandle cleanup before fire
    (must-fix 3 from review), per-run lifetime
"""
from __future__ import annotations

import asyncio
import time
import warnings

import pytest

from dso_ci_review.dispatch_ratelimit import (
    HARD_RETRY_AFTER_CEILING_S,
    SERVER_RETRY_AFTER_CAP_S,
    DispatchContext,
    calculate_backoff,
    parse_retry_after,
    should_retry,
)


class TestParseRetryAfter:
    def test_retry_after_ms(self) -> None:
        assert parse_retry_after({"retry-after-ms": "2500"}) == pytest.approx(2.5)

    def test_retry_after_ms_prefers_over_seconds(self) -> None:
        assert parse_retry_after(
            {"retry-after-ms": "1000", "retry-after": "60"}
        ) == pytest.approx(1.0)

    def test_retry_after_seconds(self) -> None:
        assert parse_retry_after({"retry-after": "30"}) == pytest.approx(30.0)

    def test_retry_after_http_date(self) -> None:
        future = time.time() + 45
        date_str = (
            __import__("email.utils", fromlist=["formatdate"])
            .formatdate(timeval=future, usegmt=True)
        )
        result = parse_retry_after({"retry-after": date_str})
        assert result is not None
        assert 40 <= result <= 50

    def test_missing_returns_none(self) -> None:
        assert parse_retry_after({}) is None
        assert parse_retry_after(None) is None

    def test_malformed_returns_none(self) -> None:
        assert parse_retry_after({"retry-after": "tomorrow"}) is None
        assert parse_retry_after({"retry-after-ms": "abc"}) is None

    def test_case_insensitive(self) -> None:
        assert parse_retry_after({"Retry-After": "10"}) == pytest.approx(10.0)


class TestCalculateBackoff:
    def test_server_supplied_within_cap(self) -> None:
        assert calculate_backoff(0, 30.0) == 30.0
        assert calculate_backoff(0, SERVER_RETRY_AFTER_CAP_S) == SERVER_RETRY_AFTER_CAP_S

    def test_server_supplied_above_cap_clamped_to_ceiling(self) -> None:
        delay = calculate_backoff(0, 250.0)
        assert delay == 250.0  # within 600s ceiling, no clamp

    def test_pathological_retry_after_clamped_to_hard_ceiling(self) -> None:
        delay = calculate_backoff(0, 86400.0)
        assert delay == HARD_RETRY_AFTER_CEILING_S

    def test_exponential_fallback_no_server_value(self) -> None:
        class FixedRng:
            @staticmethod
            def random() -> float:
                return 0.0

        for attempt in range(4):
            d = calculate_backoff(attempt, None, rng=FixedRng)
            expected = min(0.5 * (2**attempt), 8.0)
            assert d == pytest.approx(expected, rel=1e-9)

    def test_jitter_range_is_one_sided_downward(self) -> None:
        samples = [calculate_backoff(3, None) for _ in range(1000)]
        nominal = min(0.5 * (2**3), 8.0)
        ratios = [s / nominal for s in samples]
        assert min(ratios) >= 0.75 - 1e-9
        assert max(ratios) < 1.0
        avg = sum(ratios) / len(ratios)
        assert 0.85 <= avg <= 0.90

    def test_zero_or_negative_retry_after_falls_to_exponential(self) -> None:
        class FixedRng:
            @staticmethod
            def random() -> float:
                return 0.0

        assert calculate_backoff(0, 0.0, rng=FixedRng) == pytest.approx(0.5)
        assert calculate_backoff(0, -5.0, rng=FixedRng) == pytest.approx(0.5)


class _MockExc(Exception):
    def __init__(self, *, status_code: int | None = None, headers: dict | None = None) -> None:
        super().__init__("mock")
        if status_code is not None:
            self.status_code = status_code
        if headers is not None:
            self.headers = headers


class TestShouldRetry:
    def test_429_retries(self) -> None:
        assert should_retry(_MockExc(status_code=429)) is True

    def test_500_502_503_504_retry(self) -> None:
        for code in (500, 502, 503, 504):
            assert should_retry(_MockExc(status_code=code)) is True, code

    def test_408_409_retry(self) -> None:
        assert should_retry(_MockExc(status_code=408)) is True
        assert should_retry(_MockExc(status_code=409)) is True

    def test_400_401_403_404_no_retry(self) -> None:
        for code in (400, 401, 403, 404):
            assert should_retry(_MockExc(status_code=code)) is False, code

    def test_x_should_retry_true_overrides_status(self) -> None:
        assert should_retry(
            _MockExc(status_code=400, headers={"x-should-retry": "true"})
        ) is True

    def test_x_should_retry_false_short_circuits(self) -> None:
        assert should_retry(
            _MockExc(status_code=429, headers={"x-should-retry": "false"})
        ) is False

    def test_rate_limit_error_class_name_alone_retries(self) -> None:
        class RateLimitError(Exception):
            pass

        assert should_retry(RateLimitError("rl")) is True

    def test_plain_value_error_no_retry(self) -> None:
        assert should_retry(ValueError("nope")) is False


class TestDispatchContext:
    def test_create_returns_set_event(self) -> None:
        async def _check():
            ctx = DispatchContext.create()
            assert ctx.cooldown_event.is_set()
            assert ctx.cooldown_count == 0

        asyncio.run(_check())

    def test_signal_cooldown_clears_event_and_rearms(self) -> None:
        async def _flow():
            ctx = DispatchContext.create()
            ctx.signal_cooldown(0.1)
            assert not ctx.cooldown_event.is_set()
            assert ctx.cooldown_count == 1
            await asyncio.sleep(0.2)
            assert ctx.cooldown_event.is_set()
            ctx.cleanup()

        asyncio.run(_flow())

    def test_cooldown_gates_wait(self) -> None:
        async def _flow():
            ctx = DispatchContext.create()
            ctx.signal_cooldown(0.15)
            t0 = time.monotonic()
            await ctx.cooldown_event.wait()
            elapsed = time.monotonic() - t0
            assert 0.10 <= elapsed <= 0.30, elapsed
            ctx.cleanup()

        asyncio.run(_flow())

    def test_zero_delay_is_noop(self) -> None:
        async def _flow():
            ctx = DispatchContext.create()
            ctx.signal_cooldown(0.0)
            assert ctx.cooldown_event.is_set()
            assert ctx.cooldown_count == 0

        asyncio.run(_flow())

    def test_short_then_long_replaces_timer(self) -> None:
        """0.05s → 0.5s direction: shorter active timer is replaced by longer one
        (longest-wins is satisfied vacuously when the newer call is longer)."""
        async def _flow():
            ctx = DispatchContext.create()
            ctx.signal_cooldown(0.05)
            ctx.signal_cooldown(0.5)
            assert ctx.cooldown_count == 2
            assert not ctx.cooldown_event.is_set()
            await asyncio.sleep(0.15)
            assert not ctx.cooldown_event.is_set()
            ctx.cleanup()

        asyncio.run(_flow())

    def test_long_then_short_keeps_longer_timer(self) -> None:
        """Longest-wins invariant: an active 5s cooldown must NOT be shortened
        by a follow-on 0.05s call. This is the bug class that under Phase 2
        shared-context dispatch would let a sibling's exponential 0.4s
        backoff silently shrink a peer's 60s server-supplied Retry-After.
        """
        async def _flow():
            ctx = DispatchContext.create()
            ctx.signal_cooldown(5.0)
            first_handle = ctx._timer_handle
            assert first_handle is not None
            assert ctx.cooldown_count == 1
            ctx.signal_cooldown(0.05)
            assert ctx._timer_handle is first_handle, (
                "follow-on shorter signal must NOT replace the active timer"
            )
            assert ctx.cooldown_count == 1, (
                "follow-on shorter signal must NOT increment cooldown_count"
            )
            assert not first_handle.cancelled()
            await asyncio.sleep(0.15)
            assert not ctx.cooldown_event.is_set(), (
                "0.05s elapsed but the 5s cooldown should still hold"
            )
            ctx.cleanup()

        asyncio.run(_flow())

    def test_cleanup_cancels_active_timer_handle(self) -> None:
        """cleanup() must cancel any pending TimerHandle so the call_later
        callback does not fire on a destroyed/closed loop. The earlier
        warnings.catch_warnings approach was vacuous — asyncio does not emit
        Python warnings.warn() entries for uncancelled call_later handles;
        verify TimerHandle.cancelled() directly.
        """
        async def _flow():
            ctx = DispatchContext.create()
            ctx.signal_cooldown(10.0)
            handle = ctx._timer_handle
            assert handle is not None
            assert not handle.cancelled()
            ctx.cleanup()
            assert handle.cancelled(), "cleanup() failed to cancel the TimerHandle"
            assert ctx._timer_handle is None
            assert ctx.cooldown_event.is_set()
            assert ctx._cooldown_deadline is None

        asyncio.run(_flow())

    def test_per_run_lifetime_separate_instances(self) -> None:
        """Must-fix 1: each asyncio.run gets its own context, not a module singleton."""
        async def _make() -> DispatchContext:
            ctx = DispatchContext.create()
            ctx.signal_cooldown(5.0)
            return ctx

        ctx1 = asyncio.run(_make())

        async def _check_independent() -> bool:
            ctx2 = DispatchContext.create()
            return ctx2 is not ctx1 and ctx2.cooldown_event.is_set()

        assert asyncio.run(_check_independent())
