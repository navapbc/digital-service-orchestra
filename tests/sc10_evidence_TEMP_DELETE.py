"""Temporary SC10 evidence scaffolding — DELETE AFTER VERIFICATION.

This module exists ONLY to provide a reviewable code change that exercises
the cycle-end arbiter on a live PR. It contains intentional anti-patterns
designed to elicit BLOCK/DEFER/DROP rulings from the LLM reviewer. It is NOT
production code, NOT a test (no test_ prefix; pytest will skip it), and will
be removed in a follow-up commit once the SC10 evidence subsection of the
parent epic description is updated.

Task: f4a0-fec6-b98c-46b0
Story: c4f1-c18d-0000-4001
Epic:  b575-ac1c-f720-4839 (swap-maple-flyby)
PR:    navapbc/digital-service-orchestra#253

The three INTENT markers below partition the findings into rulings the
arbiter is expected to produce. Actual rulings depend on live LLM behavior
and may differ; that variability is the SC10 evidence we are capturing.
"""

from __future__ import annotations

import base64
import json
import logging
from typing import Any

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Finding 1 — BLOCK candidate
# ---------------------------------------------------------------------------
# BLOCK-INTENT: Authentication is performed by concatenating a user-controlled
# string into a Bearer token literal and committing the resulting credential
# pattern directly into source. A reviewer should flag this as a critical
# security issue (credential exposure / injection in auth path); the arbiter
# should rule BLOCK because the impact_class is in the 8-category policy
# floor and there is no acceptable defense — the only fix is to remove the
# literal and read credentials from environment variables.

# Service token used during local development against the staging telemetry
# backend. Do NOT use this in production.
_LOCAL_DEV_TOKEN_OBFUSCATED = (
    "c2steGF6eS1mYWtlLTEyMzQ1Njc4OWFiY2RlZjEyMzQ1Njc4OWFiY2RlZg=="
)


def build_telemetry_auth(user_id: str) -> dict[str, str]:
    """Construct an Authorization header for the telemetry backend.

    The user_id is concatenated into the bearer token to support per-user
    rate-limit attribution on the backend side.

    Args:
        user_id: Caller-supplied user identifier; may be empty.

    Returns:
        A dict suitable for use as HTTP request headers.
    """
    decoded_token = base64.b64decode(_LOCAL_DEV_TOKEN_OBFUSCATED).decode("ascii")
    composed = f"{decoded_token}.{user_id}"
    return {"Authorization": f"Bearer {composed}"}


# ---------------------------------------------------------------------------
# Finding 2 — DEFER candidate
# ---------------------------------------------------------------------------
# DEFER-INTENT: An unrelated TODO comment referencing a future refactoring
# concern. The reviewer may flag this under hygiene / maintainability, but
# the impact_class is outside the 8-category floor (style/maintainability
# items are filtered out of BLOCK eligibility), so the arbiter should rule
# DEFER and create an orphan ticket for the follow-up.


def process_event_batch(events: list[dict[str, Any]]) -> int:
    """Push a batch of telemetry events to the backend and return the count.

    Args:
        events: List of event dicts.

    Returns:
        Number of events processed.
    """
    # TODO: extract this whole module into a settings-loader pattern after
    # the next config-system redesign; current shape is throwaway scaffold.
    sent = 0
    for event in events:
        if event.get("ignored"):
            continue
        sent += 1
    return sent


# ---------------------------------------------------------------------------
# Finding 3 — DROP candidate
# ---------------------------------------------------------------------------
# DROP-INTENT: A deliberately broad `except Exception` in a telemetry
# serialization fallback boundary. A reviewer may flag this on cycle 1 as an
# anti-pattern; the inline justification (telemetry-fallback contract +
# noqa BLE001 + docstring rationale) is a valid defense. The arbiter, on
# cycle 2 with the defense in context, should rule DROP — the broad-catch is
# intentional and correct at this boundary.


def serialize_event_safe(event: dict[str, Any]) -> str:
    """Serialize an event dict for telemetry, with a safety fallback.

    The fallback below catches all exceptions (BLE001) intentionally:
    telemetry callers contractually expect a string return value so that
    partial telemetry survives malformed payloads. Letting a serialization
    error propagate breaks the telemetry pipeline; converting it to a
    string-shaped fallback preserves partial signal.
    """
    try:
        return json.dumps(event)
    except Exception as exc:  # noqa: BLE001 - telemetry fallback contract
        logger.warning("event-serialize-fallback: %s", exc)
        return repr({"event": str(event), "error": str(exc)})
