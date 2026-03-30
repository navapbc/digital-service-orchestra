#!/usr/bin/env python3
"""Validate a gate signal JSON payload from stdin against the gate-signal-schema contract.

Reads a single JSON object from stdin, validates all required fields with correct
types and enum values, prints the validation result to stdout on success, and exits:
  0 — valid signal conforming to the gate-signal-schema contract
  1 — invalid signal (missing fields, wrong types, bad enum values, empty object)
  2 — malformed JSON (not parseable)

See: plugins/dso/docs/contracts/gate-signal-schema.md
"""

from __future__ import annotations

import json
import sys

REQUIRED_FIELDS = ("gate_id", "triggered", "signal_type", "evidence", "confidence")

SIGNAL_TYPE_VALUES = {"primary", "modifier"}
CONFIDENCE_VALUES = {"high", "medium", "low"}


def validate(data: object) -> list[str]:
    """Return a list of error messages; empty list means valid."""
    errors: list[str] = []

    if not isinstance(data, dict):
        errors.append(f"expected a JSON object, got {type(data).__name__}")
        return errors

    if not data:
        errors.append("empty JSON object — all required fields are missing")
        return errors

    for field in REQUIRED_FIELDS:
        if field not in data:
            errors.append(f"missing required field: {field!r}")

    if errors:
        return errors

    # gate_id: string
    if not isinstance(data["gate_id"], str):
        errors.append(f"gate_id must be a string, got {type(data['gate_id']).__name__}")

    # triggered: boolean (not string, not int used as bool)
    if not isinstance(data["triggered"], bool):
        errors.append(
            f"triggered must be a boolean, got {type(data['triggered']).__name__}"
        )

    # signal_type: string enum
    if not isinstance(data["signal_type"], str):
        errors.append(
            f"signal_type must be a string, got {type(data['signal_type']).__name__}"
        )
    elif data["signal_type"] not in SIGNAL_TYPE_VALUES:
        errors.append(
            f"signal_type {data['signal_type']!r} is not one of "
            f"{sorted(SIGNAL_TYPE_VALUES)}"
        )

    # evidence: non-empty string
    if not isinstance(data["evidence"], str):
        errors.append(
            f"evidence must be a string, got {type(data['evidence']).__name__}"
        )
    elif not data["evidence"].strip():
        errors.append("evidence must not be empty")

    # confidence: string enum
    if not isinstance(data["confidence"], str):
        errors.append(
            f"confidence must be a string, got {type(data['confidence']).__name__}"
        )
    elif data["confidence"] not in CONFIDENCE_VALUES:
        errors.append(
            f"confidence {data['confidence']!r} is not one of "
            f"{sorted(CONFIDENCE_VALUES)}"
        )

    return errors


def main() -> int:
    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"ERROR: malformed JSON — {exc}", file=sys.stderr)
        return 2

    errors = validate(data)
    if errors:
        for msg in errors:
            print(f"INVALID: {msg}", file=sys.stderr)
        return 1

    result = {
        "status": "valid",
        "gate_id": data["gate_id"],
        "triggered": data["triggered"],
        "signal_type": data["signal_type"],
        "confidence": data["confidence"],
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
