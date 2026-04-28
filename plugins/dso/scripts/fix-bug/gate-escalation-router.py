#!/usr/bin/env python3
"""Gate Escalation Router.

Reads a JSON array of gate signal objects from stdin (conforming to
gate-signal-schema.md) and emits a single JSON routing decision to stdout.

Usage:
  echo '[...]' | python3 gate-escalation-router.py [--complex]

Options:
  --complex   Force escalation regardless of primary signal count.

Output schema:
  route          — one of "auto-fix", "dialog", "escalate"
  signal_count   — integer count of triggered primary signals
  dialog_context — always present; non-null when route="dialog", null otherwise

Routing rules:
  --complex flag present               → route: "escalate" (always)
  0 triggered primary signals          → route: "auto-fix"
  1 triggered primary signal           → route: "dialog"
  2+ triggered primary signals         → route: "escalate"

Modifier signals (signal_type="modifier") are NOT counted toward signal_count
but may enrich dialog_context when route="dialog".

Malformed JSON input → route: "auto-fix" (fail-open), exit 0.

Exits 0 always. Python stdlib only (json, sys).
"""

from __future__ import annotations

import json
import sys


def main() -> None:
    complex_flag = "--complex" in sys.argv[1:]

    raw = sys.stdin.read()
    try:
        signals = json.loads(raw)
        if not isinstance(signals, list):
            signals = []
    except (json.JSONDecodeError, ValueError):
        _emit_auto_fix(signal_count=0, reason="malformed JSON input")
        return

    # Separate primary and modifier signals
    primary_triggered: list[dict] = []
    modifier_evidence: list[str] = []

    for sig in signals:
        if not isinstance(sig, dict):
            continue
        triggered = sig.get("triggered", False)
        signal_type = sig.get("signal_type", "primary")

        if signal_type == "primary" and triggered:
            primary_triggered.append(sig)
        elif signal_type == "modifier" and triggered:
            evidence = sig.get("evidence", "")
            if evidence:
                modifier_evidence.append(evidence)

    signal_count = len(primary_triggered)

    # --complex forces escalation regardless of signal count
    if complex_flag:
        _emit(
            route="escalate",
            signal_count=signal_count,
            dialog_context=None,
            reason="COMPLEX classification",
            signals=[_signal_summary(s) for s in primary_triggered],
        )
        return

    if signal_count == 0:
        _emit_auto_fix(signal_count=0)
        return

    if signal_count == 1:
        primary_sig = primary_triggered[0]
        confidence = primary_sig.get("confidence", "medium")
        # question_count: 1 for high confidence, 2 otherwise
        question_count = 1 if confidence == "high" else 2

        dialog_context: dict = {
            "question_count": question_count,
            "signal": _signal_summary(primary_sig),
        }
        if modifier_evidence:
            dialog_context["modifier_evidence"] = modifier_evidence

        _emit(
            route="dialog",
            signal_count=signal_count,
            dialog_context=dialog_context,
        )
        return

    # 2+ primary signals → escalate; include all evidence
    all_signals = [_signal_summary(s) for s in primary_triggered]
    # Also include modifier evidence in escalation signals list
    escalation_signals: list[dict] = list(all_signals)
    for ev in modifier_evidence:
        escalation_signals.append({"evidence": ev, "signal_type": "modifier"})

    _emit(
        route="escalate",
        signal_count=signal_count,
        dialog_context=None,
        signals=escalation_signals,
    )


def _signal_summary(sig: dict) -> dict:
    """Extract key fields from a gate signal for routing output."""
    summary: dict = {}
    for field in ("gate_id", "signal_type", "triggered", "evidence", "confidence"):
        if field in sig:
            summary[field] = sig[field]
    return summary


def _emit_auto_fix(signal_count: int, reason: str = "") -> None:
    output: dict = {
        "route": "auto-fix",
        "signal_count": signal_count,
        "dialog_context": None,
    }
    if reason:
        output["reason"] = reason
    print(json.dumps(output))


def _emit(
    route: str,
    signal_count: int,
    dialog_context: dict | None,
    reason: str = "",
    signals: list[dict] | None = None,
) -> None:
    output: dict = {
        "route": route,
        "signal_count": signal_count,
        "dialog_context": dialog_context,
    }
    if reason:
        output["reason"] = reason
    if signals is not None:
        output["signals"] = signals
    print(json.dumps(output))


if __name__ == "__main__":
    main()
