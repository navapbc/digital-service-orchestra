"""Reconciler operation mode enum.

Mode controls what the reconciler does during each reconciliation cycle.
These modes are the ROLLOUT-SAFETY modes and are ORTHOGONAL to the
drift-injection modes used by inject-and-heal.sh (orphan, mislabel,
missing-prop), which are shell-script parameters, not passed to reconcile.py.

Ordering (ascending by operational impact):
    dry-run (0) < bootstrap-strict (1) < bootstrap-throttle (2) < live (3)

dry-run is special: it performs read-only diff analysis with no writes.
The bootstrap modes are progressive warm-up phases before full live operation.
"""

from __future__ import annotations

from enum import Enum

# Ordered list defines < / > semantics for check_phase_gate.
# Index position IS the rank; do not reorder without updating tests.
_ORDERED = [
    "dry-run",
    "bootstrap-strict",
    "bootstrap-throttle",
    "live",
]


class Mode(str, Enum):
    """Reconciler operation mode.

    Members (rollout-safety set only):
        DRY_RUN           -- read-only analysis; no Jira or ticket writes
        BOOTSTRAP_STRICT  -- conservative warm-up; writes only on high-confidence deltas
        BOOTSTRAP_THROTTLE -- permissive warm-up; writes on most deltas with rate-limiting
        LIVE              -- full production operation; no artificial throttling
    """

    DRY_RUN = "dry-run"
    BOOTSTRAP_STRICT = "bootstrap-strict"
    BOOTSTRAP_THROTTLE = "bootstrap-throttle"
    LIVE = "live"

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    @classmethod
    def from_str(cls, value: str) -> "Mode":
        """Return the Mode whose string value matches *value*.

        Raises:
            ValueError: if *value* does not match any member.  The message
                lists all four allowed values verbatim so that callers can
                surface an actionable error to the user.
        """
        for m in cls:
            if m.value == value:
                return m
        allowed = ", ".join(repr(m.value) for m in cls)
        raise ValueError(f"unknown mode {value!r}; allowed: {allowed}")

    # ------------------------------------------------------------------
    # Ordering
    # ------------------------------------------------------------------

    def rank(self) -> int:
        """Return an integer rank for ordering comparisons.

        Ordering: dry-run (0) < bootstrap-strict (1) < bootstrap-throttle (2)
        < live (3).

        Used by check_phase_gate to evaluate ``target_mode > gated_mode``.

        Example::

            if target_mode.rank() > gated_mode.rank():
                raise PhaseGateError(...)
        """
        return _ORDERED.index(self.value)
