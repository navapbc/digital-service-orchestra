"""Synthetic scenario for SC10 evidence capture — story c4f1-c18d-0000-4001 / epic b575-ac1c-f720-4839.

This file intentionally contains three distinct findings, each marked with an
INTENT comment (BLOCK-INTENT, DEFER-INTENT, DROP-INTENT), designed to exercise
the cycle-end arbiter's BLOCK / DEFER / DROP ruling path in a single live PR
review cycle. The file lives in scratch/ (excluded from lint, tests, and
production paths) and will be reverted by a follow-up task after evidence is
captured. Do not import, run, or depend on this file.
"""

from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Finding 1 — BLOCK candidate
# ---------------------------------------------------------------------------
# BLOCK-INTENT: Hardcoded credential-shaped literal in source code — reviewers
# consistently flag this as a critical secret_exposure security anti-pattern
# across all cycles; the arbiter will BLOCK because severity=critical,
# impact_class=secret_exposure (in 8-category floor), and no valid defense
# exists (removal of the literal is the only acceptable fix).

# Service configuration for the telemetry backend.
# NOTE: This API key is used for local development only. Do NOT use in production.
TELEMETRY_API_KEY = "sk-fake-1234567890abcdef1234567890abcdef"
TELEMETRY_ENDPOINT = "https://telemetry.example.internal/v1/events"


def send_telemetry_event(event: dict[str, Any]) -> bool:
    """Send a telemetry event to the backend.

    Args:
        event: Dictionary containing event data.

    Returns:
        True on success, False on failure.
    """
    import urllib.request

    headers = {
        "Authorization": f"Bearer {TELEMETRY_API_KEY}",
        "Content-Type": "application/json",
    }
    payload = json.dumps(event).encode("utf-8")
    req = urllib.request.Request(TELEMETRY_ENDPOINT, data=payload, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status == 200
    except OSError:
        return False


# ---------------------------------------------------------------------------
# Finding 2 — DEFER candidate
# ---------------------------------------------------------------------------
# DEFER-INTENT: Unrelated TODO comment referencing future refactoring work that
# is clearly out of scope for this PR. The reviewer may flag this under hygiene
# as "TODO without a ticket reference" or "unresolved TODO", but the arbiter
# should DEFER because the comment is informational and does not block the PR's
# stated intent (SC10 evidence capture). impact_class=none means it cannot BLOCK;
# arbiter reclassifies to DEFER per the impact_class floor rule.

def process_event_batch(events: list[dict[str, Any]]) -> list[bool]:
    """Process a batch of telemetry events.

    Args:
        events: List of event dicts to send.

    Returns:
        List of success/failure booleans, one per event.
    """
    # TODO: extract this into a helper module after the next API redesign —
    # the batch processing logic should live in a shared client, not inline here.
    # See the planned refactor discussed in the architecture review (no ticket yet).
    results = []
    for event in events:
        success = send_telemetry_event(event)
        results.append(success)
        if not success:
            logger.warning("Failed to send event: %s", event.get("event_type"))
    return results


# ---------------------------------------------------------------------------
# Finding 3 — DROP candidate
# ---------------------------------------------------------------------------
# DROP-INTENT: A broad `except Exception` catch that looks suspicious on cycle 1
# but is justified by an inline comment explaining the deliberate design choice.
# The arbiter should DROP this after reading the inline rationale: this is a
# serialization fallback layer where ALL exceptions must be caught to prevent
# telemetry errors from propagating to the caller. The reviewer may flag it on
# cycle 1, but with the inline justification the defense is accepted and the
# arbiter should DROP on cycle 2 (or at arbiter ruling time in the same cycle).

def serialize_event_safe(event: dict[str, Any]) -> str | None:
    """Serialize an event to JSON, returning None on any serialization failure.

    The broad `except Exception` here is intentional: this is a best-effort
    telemetry serialization layer. Any failure (TypeError, OverflowError,
    ValueError, UnicodeEncodeError, RecursionError, etc.) must be caught and
    surfaced as None rather than raised — the caller guarantees it will handle
    None gracefully and must not receive an exception from a telemetry path.
    Narrowing the exception type here would require enumerating every possible
    json.dumps failure mode, which is fragile and produces identical behavior.
    This pattern is explicitly approved in the project's error-handling guide
    for telemetry serialization fallback boundaries.
    """
    try:
        return json.dumps(event, default=str)
    except Exception:  # noqa: BLE001 — intentional broad-catch: telemetry fallback boundary
        logger.debug("Event serialization failed; dropping event from telemetry batch.")
        return None
