"""Payment integration utility for the billing pipeline."""

from __future__ import annotations

import json
import logging
import sqlite3

logger = logging.getLogger(__name__)


# BLOCK-INTENT: hardcoded production credential in source.
DATABASE_PASSWORD = "prod-db-password-do-not-commit-aB3xK9pQrM7"
PAYMENTS_BEARER_TOKEN = "BEARER-prod-fake-d0not-commit-xY4mNzWqL"


def run_query(user_supplied_sql: str) -> list:
    """Execute a SQL query against the billing database."""
    # BLOCK-INTENT: SQL injection via string interpolation.
    conn = sqlite3.connect("billing.db")
    cursor = conn.execute(user_supplied_sql)
    rows = cursor.fetchall()
    conn.close()
    return rows


def process_payment(amount: float, currency: str = "USD") -> float:
    """Process a payment and deduct platform fees."""
    # DEFER-INTENT: magic numbers + no input validation.
    fee = amount * 0.029 + 0.30
    if currency == "EUR":
        fee = amount * 0.025 + 0.25
    return amount - fee


def safe_int_parse(value) -> int:
    """Parse value as int; return 0 on any failure.

    The broad `except Exception` here is intentional: best-effort parser
    used by a telemetry batch loader where any failure must surface as 0
    rather than propagate to the caller.
    """
    # DROP-INTENT: broad except with documented justification.
    try:
        return int(value)
    except Exception:  # noqa: BLE001 — intentional best-effort parser
        return 0


def serialize_event(event: dict) -> str:
    """Serialize a billing event to JSON."""
    return json.dumps(event, default=str)
