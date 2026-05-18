"""dso_ci_review.stability — finding identity hash + Jaccard similarity + halt decision.

Used by cycle_dispatcher.next_action to determine when consecutive review cycles
have converged on a stable finding set (Jaccard >= 0.85 -> STABLE_HALT signal).

Per cycle-ledger.md contract, finding identity is computed from a stable
(file, line_range, category) tuple — NOT from free-form message text which
varies per LLM cycle.

Public functions:
    finding_hash(finding) -> str
        Stable 16-char hex digest (SHA-256 truncated) of a finding's identity.
        Accepts dict or 3-element list/tuple. Normalizes line_range across forms.

    jaccard(set_a, set_b) -> float
        Jaccard similarity between two finding sets. Zero-set edge case -> 1.0
        (both empty, or one empty = full agreement, per cycle-end Step 4.75).

    should_halt(current, prior, threshold=0.85) -> tuple[bool, str | None]
        Returns (True, "STABLE_HALT") when Jaccard >= threshold, else (False, None).
"""

from __future__ import annotations

import hashlib


def _normalize_line_range(value) -> str:
    """Normalize line_range to canonical 'start-end' (or 'n') string form.

    Accepts:
      - tuple/list of length 2 -> "start-end"
      - int                    -> "n"
      - string                 -> unchanged
      - anything else          -> str(value)
    """
    if isinstance(value, (list, tuple)) and len(value) == 2:
        return f"{value[0]}-{value[1]}"
    if isinstance(value, int):
        return str(value)
    return str(value)


def finding_hash(finding) -> str:
    """Stable 16-char hex digest of (file, line_range, category).

    Uses SHA-256 truncated to 16 hex chars rather than Python's builtin hash()
    so the value is deterministic across processes (PYTHONHASHSEED-independent).
    """
    if isinstance(finding, dict):
        file = finding.get("file", "")
        line_range = _normalize_line_range(finding.get("line_range", ""))
        category = finding.get("category", "")
    else:
        # 3-element list/tuple: (file, line_range, category)
        file = str(finding[0]) if len(finding) > 0 else ""
        line_range = _normalize_line_range(finding[1]) if len(finding) > 1 else ""
        category = str(finding[2]) if len(finding) > 2 else ""
    payload = f"{file}|{line_range}|{category}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:16]


def jaccard(set_a, set_b) -> float:
    """Jaccard similarity between two finding collections.

    Zero-set semantics:
    - Both empty: returns 1.0 (no findings on either side → stable convergence).
    - One empty, one not: returns 0.0 (mathematical Jaccard of empty vs.
      non-empty is no overlap). This prevents premature STABLE_HALT on
      cycle-1 transitions where prior_findings is empty but current
      review surfaced unresolved critical findings (bug da45 review
      finding f-a1b2c3d4).

    Callers that want to skip the stability check entirely when no prior
    cycle exists should do so before calling jaccard — see should_halt's
    prior-empty guard.
    """
    if not set_a and not set_b:
        return 1.0
    if not set_a or not set_b:
        return 0.0
    hashes_a = {finding_hash(f) for f in set_a}
    hashes_b = {finding_hash(f) for f in set_b}
    intersection = len(hashes_a & hashes_b)
    union = len(hashes_a | hashes_b)
    return intersection / union if union > 0 else 1.0


def should_halt(
    current, prior, threshold: float = 0.85
) -> tuple[bool, str | None]:
    """Decide if STABLE_HALT should fire based on Jaccard similarity.

    Returns (True, "STABLE_HALT") when jaccard(current, prior) >= threshold,
    else (False, None). Caller (cycle_dispatcher) consumes the signal to
    short-circuit further review cycles.

    Zero-set behavior is delegated to jaccard():
    - Both empty → jaccard=1.0 → halt (no findings either side, stable).
    - Prior empty + current non-empty → jaccard=0.0 → no halt (the
      cycle-1 transition with newly-surfaced findings is by definition
      not stable). Bug da45 finding f-a1b2c3d4: returning 1.0 from
      jaccard in this case used to cause premature STABLE_HALT.
    """
    score = jaccard(current, prior)
    if score >= threshold:
        return (True, "STABLE_HALT")
    return (False, None)
