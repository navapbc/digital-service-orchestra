"""dso_ci_review.arbiter — Cycle-end arbiter dispatch and ruling validation.

Provides public functions:

  dispatch_arbiter          — Dispatches the cycle-end arbiter for a list of findings.
                              Returns a list of per-finding ruling dicts.

  validate_cycle_end_ruling — Validates a ruling dict against VALID_RULINGS.
                              Raises ValueError for unrecognized ruling values.

  dispatch_cycle_end_arbiter — Alias for dispatch_arbiter; cycle-end consolidation.

  compute_ruling_from_fixture — Apply CoVe fallback and validate on a pre-stored
                                arbiter_ruling from a fixture. Used by shell replay
                                tests to exercise the deterministic arbiter pipeline
                                without requiring LLM dispatch.
"""

from __future__ import annotations

import json as _json
import subprocess
import sys
from typing import Any

from dso_ci_review.dispatch import dispatch_review

# Specific transport / parse exception classes treated as dispatch failures.
# NOTE: deliberately NOT bare `Exception` — catching `Exception` would mask
# downstream programming bugs (e.g. AttributeError in CoVe fallback) as fake
# BLOCK rulings. Only true transport/parse errors are dispatch failures.
_DISPATCH_FAILURE_EXCEPTIONS: tuple[type[BaseException], ...] = (
    subprocess.CalledProcessError,
    _json.JSONDecodeError,
    OSError,  # base class for ConnectionError, TimeoutError, FileNotFoundError, etc.
)

VALID_RULINGS: frozenset[str] = frozenset({"BLOCK", "DEFER", "DROP"})


def validate_cycle_end_ruling(ruling: dict[str, Any]) -> dict[str, Any]:
    """Validate a cycle-end ruling dict against VALID_RULINGS.

    Args:
        ruling: A ruling dict with a 'ruling' key.

    Returns:
        The ruling dict unchanged if valid.

    Raises:
        ValueError: If ruling['ruling'] is not in VALID_RULINGS.
    """
    ruling_value = ruling.get("ruling", "")
    if ruling_value not in VALID_RULINGS:
        raise ValueError(
            f"Unknown ruling {ruling_value!r}. Must be one of {sorted(VALID_RULINGS)}"
        )
    return ruling


def _enforce_cove_fallback(
    ruling: dict[str, Any], cycle_num: int, max_cycles: int
) -> dict[str, Any]:
    """Reclassify BLOCK to DEFER when cycle_num exceeds max_cycles (CoVe soft-cap).

    Args:
        ruling: A ruling dict with a 'ruling' key.
        cycle_num: Current review cycle number.
        max_cycles: Configured maximum review cycles.

    Returns:
        The ruling dict, with ruling='DEFER' if BLOCK was issued past the cycle cap.
    """
    if ruling.get("ruling") == "BLOCK" and cycle_num > max_cycles:
        result = dict(ruling)
        result["ruling"] = "DEFER"
        result["rationale"] = (
            f"CoVe soft-cap: cycle_num={cycle_num} > max_cycles={max_cycles} — "
            "BLOCK reclassified to DEFER to force convergence"
        )
        return result
    return ruling


def compute_ruling_from_fixture(fixture: dict) -> dict:
    """Apply CoVe fallback and validate on a pre-stored arbiter_ruling from a fixture.

    Used by shell replay tests to exercise the deterministic arbiter pipeline
    (CoVe soft-cap + ruling validation) without requiring LLM dispatch.

    Args:
        fixture: dict with keys 'arbiter_ruling', 'cycle', 'max_cycles'

    Returns:
        The effective ruling dict after CoVe fallback and validation.

    Raises:
        ValueError: if ruling is not in VALID_RULINGS after CoVe fallback.
    """
    ruling = dict(fixture["arbiter_ruling"])
    cycle_num = int(fixture.get("cycle", 1))
    max_cycles = int(fixture.get("max_cycles", 4))
    ruling = _enforce_cove_fallback(ruling, cycle_num, max_cycles)
    return validate_cycle_end_ruling(ruling)


def dispatch_arbiter(
    findings: list[dict[str, Any]],
    defenses: list[dict[str, Any]],
    diff_text: str,
    model: str,
    provider_chain: list[str],
    cycle_num: int,
    max_cycles: int,
) -> list[dict[str, Any]]:
    """Dispatch the cycle-end consolidation arbiter for a list of findings.

    Calls the code-reviewer-arbiter agent via dispatch_review and processes
    each finding's ruling through CoVe fallback and validation.

    Args:
        findings: List of unresolved finding dicts from the current review cycle.
        defenses: List of defense dicts submitted across all cycles.
        diff_text: Unified diff text under review.
        model: Primary model identifier to use.
        provider_chain: Ordered list of provider names.
        cycle_num: Current review cycle number.
        max_cycles: Configured maximum review cycles.

    Returns:
        A list of per-finding ruling dicts, each containing:
        - ruling: one of BLOCK, DEFER, DROP
        - rationale: one-sentence explanation
        - schema_version: "1.0.0"

    The agent contract (see the ``code-reviewer-arbiter`` agent file under
    ``${CLAUDE_PLUGIN_ROOT}/agents/``) specifies the output as a JSON array
    with one element per input finding. A single dict response is accepted
    for backward compatibility and wrapped in a list.

    Length-mismatch handling (AC amendment): if the agent returns a number of
    rulings that does not match the input findings, dispatch is treated as a
    failure and the function emits fail-closed synthetic BLOCK rulings for
    every critical/important finding (matches T2 fail-closed behavior). The
    mismatch is logged to stderr as ``arbiter_length_mismatch``.

    Dispatch-failure handling (AC amendment, T2): if dispatch_review raises a
    transport/parse failure (subprocess.CalledProcessError, json.JSONDecodeError,
    or any OSError including ConnectionError/TimeoutError), the function emits
    fail-closed synthetic BLOCK rulings for every critical/important finding.
    Each synthetic ruling preserves the original ``severity`` and the input
    ``finding_index``. Empty findings + dispatch failure returns an empty list
    (no synthetic BLOCK for a nonexistent finding). The failure is logged to
    stderr as ``arbiter_dispatch_failed reason=<exc> finding_count=<n>``.

    NOTE: bare ``Exception`` is intentionally NOT caught — that would mask
    downstream programming bugs as fake BLOCK rulings, defeating the purpose
    of the fail-closed signal.
    """
    # Empty findings: no dispatch needed, return empty (no synthetic BLOCK for
    # nonexistent findings — would be meaningless and would pollute the gate).
    if not findings:
        return []

    try:
        result = dispatch_review(
            diff=diff_text,
            agent_id="code-reviewer-arbiter",
            primary_model=model,
            provider_chain=provider_chain,
        )
    except _DISPATCH_FAILURE_EXCEPTIONS as exc:
        print(
            f"arbiter_dispatch_failed reason={type(exc).__name__} "
            f"finding_count={len(findings)}",
            file=sys.stderr,
        )
        exc_msg = str(exc)[:200]
        return [
            {
                "ruling": "BLOCK",
                "rationale": (
                    f"Arbiter dispatch failed: {type(exc).__name__}: {exc_msg}; "
                    "defaulting to BLOCK; manual review required."
                ),
                "schema_version": "1.0.0",
                "finding_index": i,
                "severity": finding.get("severity", ""),
                "finding_hash": finding.get("finding_hash", ""),
            }
            for i, finding in enumerate(findings)
            if finding.get("severity") in ("critical", "important")
        ]

    # Agent contract: returns a JSON array of per-finding rulings.
    # Backward-compat: a single-ruling dict response is wrapped in a list.
    if isinstance(result, dict):
        rulings_list = [result]
    elif isinstance(result, list):
        rulings_list = result
    else:
        raise ValueError(
            f"Arbiter returned unexpected type: {type(result).__name__}; "
            "expected list of per-finding ruling dicts or a single ruling dict."
        )

    # Length-mismatch detection (AC amendment): treat as dispatch failure.
    if len(rulings_list) != len(findings):
        print(
            f"arbiter_length_mismatch findings={len(findings)} "
            f"rulings={len(rulings_list)}",
            file=sys.stderr,
        )
        return [
            {
                "ruling": "BLOCK",
                "rationale": (
                    f"Arbiter response length mismatch (got {len(rulings_list)} "
                    f"rulings for {len(findings)} findings); defaulting to BLOCK; "
                    "manual review required."
                ),
                "schema_version": "1.0.0",
                "finding_index": i,
                "severity": finding.get("severity", ""),
                "finding_hash": finding.get("finding_hash", ""),
            }
            for i, finding in enumerate(findings)
            if finding.get("severity") in ("critical", "important")
        ]

    # Per-finding processing: schema_version, CoVe fallback, validation.
    validated_rulings: list[dict[str, Any]] = []
    for ruling in rulings_list:
        if "schema_version" not in ruling:
            ruling["schema_version"] = "1.0.0"
        ruling = _enforce_cove_fallback(ruling, cycle_num, max_cycles)
        validate_cycle_end_ruling(ruling)
        validated_rulings.append(ruling)

    return validated_rulings


def dispatch_cycle_end_arbiter(
    findings: list[dict[str, Any]],
    defenses: list[dict[str, Any]],
    diff_text: str,
    model: str,
    provider_chain: list[str],
    cycle_num: int,
    max_cycles: int,
) -> list[dict[str, Any]]:
    """Cycle-end consolidation arbiter entry point. Delegates to dispatch_arbiter.

    Args:
        findings: List of unresolved finding dicts.
        defenses: List of defense dicts.
        diff_text: Unified diff text under review.
        model: Primary model identifier.
        provider_chain: Ordered list of provider names.
        cycle_num: Current review cycle number.
        max_cycles: Configured maximum review cycles.

    Returns:
        List of per-finding ruling dicts from dispatch_arbiter.
    """
    return dispatch_arbiter(
        findings, defenses, diff_text, model, provider_chain, cycle_num, max_cycles
    )
