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
    When _is_verifier_enabled() returns False, returns findings unchanged.
- dispatch_verifier_with_telemetry(findings, reviewed_sha) → tuple[list, dict]
    Like dispatch_verifier but also returns a telemetry counters dict.
- _is_verifier_enabled() → bool
    Reads review.verifier_enabled from dso-config.conf. Default: False.
- _validate_failure_threshold(threshold) → None
    Validates that threshold is in range (0.0, 1.0]. Raises ValueError if not.
- _check_cascade_brake(failure_rate, in_scope_count) → bool
    Returns True if cascade brake should activate.
- _call_verifier_agent(finding, reviewed_sha) → VerifierResult
    Internal stub. Always mocked in tests. Raises NotImplementedError if called
    without a mock.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass


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
# Feature flag and configuration helpers
# ---------------------------------------------------------------------------


def _is_verifier_enabled() -> bool:
    """Read review.verifier_enabled from dso-config.conf. Default: False."""
    try:
        result = subprocess.run(
            [
                "bash",
                "-c",
                "grep -m1 '^review.verifier_enabled=' ~/.claude/dso-config.conf 2>/dev/null || "
                "find . -name 'dso-config.conf' -maxdepth 4 2>/dev/null | head -1 | "
                "xargs grep -m1 '^review.verifier_enabled=' 2>/dev/null || echo ''",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        val = result.stdout.strip()
        return val.endswith("=true") or val == "true"
    except Exception:
        return False


def _validate_failure_threshold(threshold: float) -> None:
    """Validate that threshold is in range (0.0, 1.0]. Raises ValueError if not."""
    if threshold <= 0.0 or threshold > 1.0:
        raise ValueError(
            f"review.verifier_failure_threshold={threshold} out of range (0.0, 1.0]"
        )


def _read_failure_threshold() -> float:
    """Read review.verifier_failure_threshold from dso-config.conf. Default: 0.30."""
    try:
        result = subprocess.run(
            [
                "bash",
                "-c",
                "grep -m1 '^review.verifier_failure_threshold=' ~/.claude/dso-config.conf 2>/dev/null || "
                "find . -name 'dso-config.conf' -maxdepth 4 2>/dev/null | head -1 | "
                "xargs grep -m1 '^review.verifier_failure_threshold=' 2>/dev/null || echo ''",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        val = result.stdout.strip()
        if not val:
            return 0.30
        raw = val.split("=", 1)[-1].strip()
        threshold = float(raw)
        _validate_failure_threshold(threshold)
        return threshold
    except Exception:
        return 0.30


def _check_cascade_brake(
    failure_rate: float, in_scope_count: int, threshold: float = 0.30
) -> bool:
    """Return True if cascade brake should activate (failure_rate > threshold AND >= 5 findings)."""
    return failure_rate > threshold and in_scope_count >= 5


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

    When ``_is_verifier_enabled()`` returns False, findings are returned
    unchanged without calling the verifier agent.

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
    if not _is_verifier_enabled():
        return list(findings)

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


def dispatch_verifier_with_telemetry(
    findings: list[dict],
    reviewed_sha: str,
) -> tuple[list[dict], dict]:
    """Like dispatch_verifier but also returns a telemetry counters dict.

    When ``_is_verifier_enabled()`` returns False, findings are returned
    unchanged with zeroed telemetry counters.

    Returns
    -------
    tuple[list[dict], dict]
        ``(processed_findings, telemetry)`` where telemetry keys are:
        ``verifier_confirm_count``, ``verifier_downgrade_count``,
        ``verifier_drop_count``, ``verifier_failure_rate``,
        ``verifier_minor_finding_rate``, ``verifier_fingerprints``.
    """
    if not _is_verifier_enabled():
        minor_count = sum(1 for f in findings if f.get("severity") == "minor")
        minor_rate = minor_count / len(findings) if findings else 0.0
        telemetry: dict = {
            "verifier_confirm_count": 0,
            "verifier_downgrade_count": 0,
            "verifier_drop_count": 0,
            "verifier_failure_rate": 0.0,
            "verifier_minor_finding_rate": minor_rate,
            "verifier_fingerprints": [],
        }
        return list(findings), telemetry

    confirm_count = 0
    downgrade_count = 0
    drop_count = 0
    failure_count = 0
    fingerprints: list[str] = []

    in_scope = [f for f in findings if f.get("severity") in _VERIFIER_SEVERITIES]
    minor_count = sum(1 for f in findings if f.get("severity") in _BYPASS_SEVERITIES)

    result_findings: list[dict] = []

    # Findings outside the verifier scope (minor + unknown severities) bypass verifier — returned as-is.
    result_findings.extend(
        f for f in findings if f.get("severity") not in _VERIFIER_SEVERITIES
    )

    for finding in in_scope:
        try:
            ruling = _call_verifier_agent(finding, reviewed_sha=reviewed_sha)
            fingerprints.append(ruling.fingerprint)
            if ruling.ruling == "drop":
                drop_count += 1
                continue
            elif ruling.ruling == "downgrade-to-minor":
                downgrade_count += 1
                f = dict(finding)
                f["severity"] = "minor"
                f["verifier_status"] = ruling.verifier_status
                result_findings.append(f)
            else:  # confirm
                confirm_count += 1
                f = dict(finding)
                f["verifier_status"] = ruling.verifier_status
                result_findings.append(f)
        except Exception:
            failure_count += 1
            f = dict(finding)
            f["verifier_status"] = "failed"
            result_findings.append(f)

    total_in_scope = len(in_scope)
    failure_rate = failure_count / total_in_scope if total_in_scope > 0 else 0.0
    minor_rate = minor_count / len(findings) if findings else 0.0

    _threshold = _read_failure_threshold()
    brake_activated = _check_cascade_brake(failure_rate, total_in_scope, _threshold)

    telemetry = {
        "verifier_confirm_count": confirm_count,
        "verifier_downgrade_count": downgrade_count,
        "verifier_drop_count": drop_count,
        "verifier_failure_rate": failure_rate,
        "verifier_minor_finding_rate": minor_rate,
        "verifier_fingerprints": fingerprints,
        "verifier_brake_activated": brake_activated,
    }

    return result_findings, telemetry
