"""dso_ci_review.verifier — Post-review evidence verification.

This module dispatches each critical/important/fragile finding to a verifier
agent that re-runs the evidence commands cited in the finding and determines
whether the finding is still valid.

Evidence commands are expected to be deterministic (grep/stat/ls/find).
Timestamp-based commands (date, stat -c %Y, etc.) may produce non-deterministic
output and should be treated with care when interpreting verifier results.

Public API
----------
- VerifierResult   — dataclass holding verifier agent output
- dispatch_verifier(findings, reviewed_sha) → list[dict]
    Entry point. Minor findings bypass the verifier. Critical/important/fragile
    findings are sent to _call_verifier_agent one at a time.
- _call_verifier_agent(finding, reviewed_sha) → VerifierResult
    Internal stub. Always mocked in tests. Raises NotImplementedError if called
    without a mock.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclass
class VerifierResult:
    """Result returned by the verifier agent for a single finding.

    Fields
    ------
    finding_id : str
        Identifier of the finding that was verified.
    ruling : str
        One of "confirm", "downgrade-to-minor", or "drop".
    fingerprint : str
        Location fingerprint in ``path:N-M`` format, or ``path:0-0`` as a
        sentinel when line numbers are unavailable.
    verifier_status : str
        "ok" if verification completed normally, "failed" if the agent call
        raised an exception (set by the caller, not by the agent).
    evidence_invalidated : bool
        True if the evidence cited in the finding no longer matches the repo
        at ``reviewed_sha``.
    rationale : str
        Human-readable explanation of the ruling.
    """

    finding_id: str
    ruling: str
    fingerprint: str
    verifier_status: str
    evidence_invalidated: bool
    rationale: str


# ---------------------------------------------------------------------------
# Internal agent stub
# ---------------------------------------------------------------------------


def _call_verifier_agent(finding: dict, reviewed_sha: str) -> VerifierResult:
    """Call the verifier agent for a single finding.

    This is a stub implementation. All tests mock this function via
    ``dso_ci_review.verifier._call_verifier_agent``.

    Parameters
    ----------
    finding:
        The finding dict to verify.
    reviewed_sha:
        The exact git SHA that was reviewed. Must be passed to the verifier
        agent so it can check out the correct version of affected files.

    Raises
    ------
    NotImplementedError
        Always — this stub must not be called without a mock in place.
    """
    raise NotImplementedError(
        "_call_verifier_agent is a stub. "
        "In production this will dispatch to the verifier LLM agent. "
        "In tests, mock dso_ci_review.verifier._call_verifier_agent."
    )


# ---------------------------------------------------------------------------
# Public dispatch function
# ---------------------------------------------------------------------------

_BYPASS_SEVERITIES = {"minor"}
_VERIFIER_SEVERITIES = {"critical", "important", "fragile"}


def dispatch_verifier(
    findings: list[dict],
    reviewed_sha: str,
) -> list[dict]:
    """Dispatch verifier checks for all non-minor findings.

    Minor findings bypass the verifier entirely — they are returned as-is
    without a ``verifier_status`` field.

    For critical, important, and fragile findings, ``_call_verifier_agent``
    is called. The ruling from the returned ``VerifierResult`` is applied:

    - ``"confirm"``             → finding returned unchanged (``verifier_status`` set)
    - ``"downgrade-to-minor"``  → ``finding["severity"]`` set to ``"minor"``,
                                   ``verifier_status`` set
    - ``"drop"``                → finding removed from results (``None`` returned
                                   for this finding)

    If ``_call_verifier_agent`` raises any exception the finding is annotated
    with ``verifier_status: "failed"`` and included in results with its
    original severity unchanged (fail-open).

    Parameters
    ----------
    findings:
        List of finding dicts as produced by the review pipeline.
    reviewed_sha:
        The exact git SHA that was reviewed. Forwarded to the verifier agent.

    Returns
    -------
    list[dict]
        Processed findings. May be shorter than the input if any findings
        received a ``"drop"`` ruling.
    """
    results: list[dict] = []

    for finding in findings:
        severity = finding.get("severity", "")

        # Minor findings bypass the verifier entirely — returned as-is.
        if severity in _BYPASS_SEVERITIES or severity not in _VERIFIER_SEVERITIES:
            results.append(finding)
            continue

        # Attempt to call the verifier agent.
        try:
            verifier_result: VerifierResult = _call_verifier_agent(
                finding, reviewed_sha=reviewed_sha
            )
        except Exception:
            # Fail-open: annotate with failed status, preserve severity.
            annotated = dict(finding)
            annotated["verifier_status"] = "failed"
            results.append(annotated)
            continue

        # Apply the ruling.
        ruling = verifier_result.ruling

        if ruling == "drop":
            # Silently remove the finding from results.
            continue

        annotated = dict(finding)
        annotated["verifier_status"] = verifier_result.verifier_status

        if ruling == "downgrade-to-minor":
            annotated["severity"] = "minor"

        # "confirm" falls through with severity unchanged.
        results.append(annotated)

    return results
