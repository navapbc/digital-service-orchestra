#!/usr/bin/env python3
"""Feature-Request Gate: Feature-Request Language Check.

Reads a JSON payload from stdin:
  {
    "title":       "<string>",
    "description": "<string>"
  }

Emits a single JSON gate signal to stdout conforming to gate-signal-schema.md:
  {
    "gate_id":     "feature_request",
    "signal_type": "primary",
    "triggered":   <bool>,
    "evidence":    "<string>",
    "confidence":  "high" | "medium" | "low"
  }

Exits 0 always.

Design:
- Searches the combined title+description text for feature-request language patterns.
- "Domain handle" false-positive guard runs first: "doesn't handle" in title is
  suppressed when the title contains a domain noun ending in "handler" or
  "handler " prefix, AND the description contains a regression/broken-behavior
  indicator.  This check must precede the combined regression check; otherwise
  any regression indicator in the description would be caught by the combined
  check first, making the guard unreachable.
- If a regression indicator is present anywhere in the combined text, the
  feature-request trigger is suppressed (regression indicators take precedence).
- Feature patterns are compiled without re.DOTALL so wildcard spans (e.g.
  "can't.*yet") cannot match across newlines, preventing cross-paragraph false
  positives in long multi-paragraph bug descriptions.
- stdlib only: json, sys, re.
"""

from __future__ import annotations

import json
import re
import sys

# ---------------------------------------------------------------------------
# Patterns
# ---------------------------------------------------------------------------

# Feature-request language patterns (case-insensitive).
# Order matters: the first match determines evidence text.
_FEATURE_PATTERNS: list[tuple[str, str]] = [
    # "missing X capability" / "missing X feature"
    (
        r"missing\s+\S+(?:\s+\S+)?\s+(?:capability|feature)",
        "matched 'missing * capability/feature' pattern",
    ),
    # "missing * support/option/ability/functionality/integration" — broader than the
    # first pattern but still requires a qualifying capability noun so that genuine
    # bug titles like "Missing data after save" do NOT trigger.
    (
        r"\bmissing\b.*?\b(?:support|option|ability|functionality|integration)\b",
        "matched 'missing * support/option/ability/functionality/integration' pattern",
    ),
    # "doesn't support", "doesn't accept", "doesn't handle"
    (
        r"doesn['\u2019]t\s+(?:support|accept|handle)\b",
        "matched 'doesn\u2019t support/accept/handle' pattern",
    ),
    # "no way to"
    (
        r"\bno\s+way\s+to\b",
        "matched 'no way to' pattern",
    ),
    # "can't * yet"
    (
        r"can['\u2019]t\b.*?\byet\b",
        "matched 'can\u2019t ... yet' pattern",
    ),
    # "unable to * new" / "unable to * any"
    (
        r"\bunable\s+to\b.*?\b(?:new|any)\b",
        "matched 'unable to ... new/any' pattern",
    ),
]

# Regression indicators: presence of any of these suppresses the feature-request
# trigger because they signal the user is describing existing/broken behaviour.
_REGRESSION_PATTERNS: list[str] = [
    r"\banymore\b",
    r"\bstopped\s+working\b",
    r"\bused\s+to\b",
    r"\bbroke\b",
    r"\bbroken\b",
    r"\bregression\b",
    r"\bsince\s+v\d",  # "since v2.3"
    r"\bafter\s+update\b",
]

# Compiled once at module load.
# Note: feature patterns intentionally omit re.DOTALL so that wildcard spans
# (e.g. "can't.*yet", "unable to.*any") cannot cross newline boundaries and
# produce false positives in multi-paragraph descriptions.
_COMPILED_FEATURE = [
    (re.compile(pat, re.IGNORECASE), label) for pat, label in _FEATURE_PATTERNS
]
_COMPILED_REGRESSION = [
    re.compile(pat, re.IGNORECASE | re.DOTALL) for pat in _REGRESSION_PATTERNS
]


# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------


def _has_regression_indicator(text: str) -> str | None:
    """Return a description of the matched regression indicator, or None."""
    for pattern in _COMPILED_REGRESSION:
        m = pattern.search(text)
        if m:
            return f"regression indicator '{m.group(0)}' found"
    return None


def _has_domain_handle_false_positive(title: str, description: str) -> bool:
    """Return True when 'doesn't handle' is a domain-noun false positive.

    Condition:
      - Title contains "handler" (case-insensitive) — meaning the subject is
        a domain component whose name ends in "handler".
      - Description contains a regression/broken-behaviour indicator.

    This prevents classifying "Payment handler doesn't handle refunds correctly
    (broken since last deploy)" as a feature request.
    """
    if not re.search(r"\bhandler\b", title, re.IGNORECASE):
        return False
    if not re.search(r"doesn['\u2019]t\s+handle", title, re.IGNORECASE):
        return False
    # Check description for regression signals
    return bool(_has_regression_indicator(description))


def _find_feature_match(text: str) -> tuple[re.Match[str], str] | None:
    """Return (match, label) for the first feature-request pattern hit, or None."""
    for pattern, label in _COMPILED_FEATURE:
        m = pattern.search(text)
        if m:
            return m, label
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        # Malformed input: emit not-triggered with low confidence.
        _emit(
            triggered=False,
            evidence=f"Could not parse stdin JSON: {exc}",
            confidence="low",
        )
        return

    title: str = payload.get("title") or ""
    description: str = payload.get("description") or ""
    combined = f"{title} {description}".strip()

    if not combined:
        _emit(
            triggered=False,
            evidence="Empty title and description; no feature-request signals to evaluate",
            confidence="high",
        )
        return

    # Domain handle false-positive guard runs first (before combined regression
    # check) because it relies on description-scoped regression signals.  If the
    # combined check ran first, any regression indicator in the description would
    # suppress the trigger before the domain-handle guard could be reached.
    if _has_domain_handle_false_positive(title, description):
        _emit(
            triggered=False,
            evidence=(
                "Domain handle false-positive suppressed: title references a 'handler' "
                "component and description contains regression indicators"
            ),
            confidence="high",
        )
        return

    # Check regression indicators across combined text.
    regression_note = _has_regression_indicator(combined)
    if regression_note:
        _emit(
            triggered=False,
            evidence=f"Feature-request check suppressed: {regression_note} in combined text",
            confidence="high",
        )
        return

    # Search for feature-request language.
    result = _find_feature_match(combined)
    if result is not None:
        match_obj, label = result
        _emit(
            triggered=True,
            evidence=f"Feature-request language detected: {label} (matched: '{match_obj.group(0)}')",
            confidence="high",
        )
        return

    _emit(
        triggered=False,
        evidence="No feature-request language patterns detected in title or description",
        confidence="high",
    )


def _emit(*, triggered: bool, evidence: str, confidence: str) -> None:
    signal = {
        "gate_id": "feature_request",
        "signal_type": "primary",
        "triggered": triggered,
        "evidence": evidence,
        "confidence": confidence,
    }
    print(json.dumps(signal))


if __name__ == "__main__":
    main()
