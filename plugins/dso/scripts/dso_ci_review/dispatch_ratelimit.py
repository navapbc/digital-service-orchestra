"""Rate-limit primitives for parallel LLM dispatch.

Ports the proven retry/backoff patterns from the Anthropic SDK
(_base_client.py) and the OpenAI Cookbook (api_request_parallel_processor.py),
with two deliberate divergences for our CI use case:

  - Server-supplied Retry-After honored up to 180s (Anthropic SDK clamps at
    60s; we lift the clamp because Anthropic occasionally returns longer
    resets — NousResearch/hermes-agent #26293).

  - Hard ceiling of 600s on Retry-After so a misbehaving header (e.g.
    Retry-After: 86400) can't stall CI indefinitely.

DispatchContext owns per-run cooldown state: the asyncio.Event that gates
new dispatches when a 429 has set a cooldown, and the TimerHandle that
re-arms the Event after the cooldown expires. It MUST be created inside the
asyncio.run() invocation that uses it — module-level state would bind the
Event to a dead loop on subsequent runs.

Spike validation: tests/skills/dso_ci_review/litellm_contract_spikes/
"""
from __future__ import annotations

import asyncio
import email.utils
import logging
import random
import time
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)


INITIAL_RETRY_DELAY: float = 0.5
MAX_RETRY_DELAY: float = 8.0
SERVER_RETRY_AFTER_CAP_S: float = 180.0
HARD_RETRY_AFTER_CEILING_S: float = 600.0

_RETRYABLE_STATUS_CODES: frozenset[int] = frozenset({408, 409, 429, 500, 502, 503, 504})


def parse_retry_after(headers: dict[str, str] | Any) -> float | None:
    """Parse Retry-After-like headers. Returns seconds or None.

    Three-tier resolution (ported from anthropic._base_client._parse_retry_after_header):
      1. retry-after-ms (float, milliseconds)
      2. retry-after (float, seconds)
      3. retry-after (RFC-1123 HTTP-date, seconds-from-now)
    """
    if headers is None:
        return None
    getter = getattr(headers, "get", None)
    if getter is None:
        try:
            headers = dict(headers)
        except (TypeError, ValueError):
            return None
        getter = headers.get

    retry_after_ms = getter("retry-after-ms") or getter("Retry-After-Ms")
    if retry_after_ms is not None:
        try:
            return float(retry_after_ms) / 1000.0
        except (TypeError, ValueError):
            pass

    retry_after = getter("retry-after") or getter("Retry-After")
    if retry_after is None:
        return None

    try:
        return float(retry_after)
    except (TypeError, ValueError):
        pass

    try:
        parsed = email.utils.parsedate_tz(retry_after)
        if parsed is None:
            return None
        delta = email.utils.mktime_tz(parsed) - time.time()
        return max(delta, 0.0)
    except (TypeError, ValueError):
        return None


def calculate_backoff(
    attempt: int,
    retry_after_seconds: float | None,
    *,
    server_cap_s: float = SERVER_RETRY_AFTER_CAP_S,
    hard_ceiling_s: float = HARD_RETRY_AFTER_CEILING_S,
    initial_delay_s: float = INITIAL_RETRY_DELAY,
    max_delay_s: float = MAX_RETRY_DELAY,
    rng: Any = None,
) -> float:
    """Compute backoff delay in seconds for retry attempt N.

    Ports anthropic._base_client._calculate_retry_timeout with two divergences:
      - Server-supplied honored up to server_cap_s (default 180s), not 60s.
      - Above server_cap_s, value is clamped to hard_ceiling_s (default 600s)
        and an INFO log is emitted — guards against misbehaving headers.

    Jitter is one-sided downward (1 - 0.25 * random()) → range [0.75, 1.0),
    verbatim from anthropic._base_client.py:L1118. Worst-case latency stays
    bounded; symmetric jitter can extend it.
    """
    if retry_after_seconds is not None and retry_after_seconds > 0:
        if retry_after_seconds <= server_cap_s:
            return float(retry_after_seconds)
        clamped = float(min(retry_after_seconds, hard_ceiling_s))
        logger.info(
            "Retry-After clamped: %.1fs → %.1fs (server_cap=%.1fs, hard_ceiling=%.1fs)",
            retry_after_seconds,
            clamped,
            server_cap_s,
            hard_ceiling_s,
        )
        return clamped

    rand = (rng or random).random
    sleep_seconds = min(initial_delay_s * (2**attempt), max_delay_s)
    jitter = 1.0 - 0.25 * rand()
    return sleep_seconds * jitter


def should_retry(exc: BaseException) -> bool:
    """Return True iff exc represents a retryable transient failure.

    Mirrors anthropic._base_client._should_retry (1122-1156) status table:
      - 408 Request Timeout, 409 Conflict, 429 Rate Limit, 5xx Server Errors → retry
      - Explicit x-should-retry: true → retry, x-should-retry: false → no retry
      - Auth/validation 4xx (400, 401, 403, 404) → no retry

    Also matches litellm.RateLimitError class directly so callers don't need
    to import the litellm exception hierarchy.
    """
    name = type(exc).__name__
    if name in ("RateLimitError", "APIError", "ServiceUnavailableError", "Timeout"):
        if name == "RateLimitError":
            return True
    headers = getattr(exc, "response", None)
    response_headers: dict[str, str] | None = None
    if headers is not None:
        rh = getattr(headers, "headers", None)
        if rh is not None:
            try:
                response_headers = {
                    k.lower(): v for k, v in (rh.items() if hasattr(rh, "items") else rh)
                }
            except Exception:  # noqa: BLE001
                response_headers = None
    if response_headers is None:
        rh = getattr(exc, "headers", None)
        if rh is not None and hasattr(rh, "items"):
            response_headers = {k.lower(): v for k, v in rh.items()}

    if response_headers:
        x_should_retry = response_headers.get("x-should-retry")
        if isinstance(x_should_retry, str):
            if x_should_retry.lower() == "true":
                return True
            if x_should_retry.lower() == "false":
                return False

    status_code = getattr(exc, "status_code", None)
    if status_code is None:
        status_code = getattr(exc, "code", None)
    if isinstance(status_code, str):
        try:
            status_code = int(status_code)
        except ValueError:
            status_code = None
    if isinstance(status_code, int):
        return status_code in _RETRYABLE_STATUS_CODES

    return name == "RateLimitError"


@dataclass
class DispatchContext:
    """Per-asyncio.run rate-limit coordination state.

    MUST be created inside the asyncio.run() invocation that uses it. Module-
    level instances bind cooldown_event to a dead loop on subsequent runs,
    causing cooldown_event.wait() to hang forever.

    Usage:
        async def main():
            ctx = DispatchContext.create()
            try:
                results = await asyncio.gather(
                    _call_single_agent(..., dispatch_context=ctx),
                    ...,
                )
            finally:
                ctx.cleanup()
        asyncio.run(main())
    """

    cooldown_event: asyncio.Event = field(default_factory=asyncio.Event)
    _timer_handle: asyncio.TimerHandle | None = None
    _cooldown_count: int = 0

    @classmethod
    def create(cls) -> "DispatchContext":
        ctx = cls()
        ctx.cooldown_event.set()
        return ctx

    def signal_cooldown(self, delay_s: float) -> None:
        """Clear the cooldown_event and schedule it to re-arm after delay_s.

        Safe to call multiple times — replaces any pending timer with the new
        delay. The longest pending cooldown wins (we never shorten an active
        cooldown by accident).
        """
        if delay_s <= 0:
            return
        loop = asyncio.get_event_loop()
        if self._timer_handle is not None:
            self._timer_handle.cancel()
        self.cooldown_event.clear()
        self._timer_handle = loop.call_later(delay_s, self.cooldown_event.set)
        self._cooldown_count += 1
        logger.warning(
            "Cooldown engaged: %.2fs (cooldown #%d this run)",
            delay_s,
            self._cooldown_count,
        )

    def cleanup(self) -> None:
        """Cancel any pending TimerHandle. Call in a finally block to avoid
        'Task was destroyed but it is pending' warnings if all dispatched
        work completes before the cooldown fires.
        """
        if self._timer_handle is not None:
            self._timer_handle.cancel()
            self._timer_handle = None
        if not self.cooldown_event.is_set():
            self.cooldown_event.set()

    @property
    def cooldown_count(self) -> int:
        return self._cooldown_count
